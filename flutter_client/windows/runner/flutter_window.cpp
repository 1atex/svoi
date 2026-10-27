#include "flutter_window.h"

#include <optional>
#include <map>
#include <flutter/standard_method_codec.h>
#include <commdlg.h>
#include <shellapi.h>
#include <shlwapi.h>
#include <windowsx.h>
#include <commctrl.h>
#include <dwmapi.h>
#include <cmath>
#include "utils.h"
#include "resource.h"
#include "external_url.h"

#include "flutter/generated_plugin_registrant.h"

namespace {
constexpr UINT kTrayMessage = WM_APP + 10;
const UINT kTaskbarCreated = RegisterWindowMessageW(L"TaskbarCreated");
NOTIFYICONDATAW TrayData(HWND hwnd) {
  NOTIFYICONDATAW data{};
  data.cbSize = sizeof(data);
  data.hWnd = hwnd;
  data.uID = 1;
  data.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  data.uCallbackMessage = kTrayMessage;
  data.hIcon = static_cast<HICON>(LoadImageW(
      GetModuleHandle(nullptr), MAKEINTRESOURCEW(IDI_TRAY_ICON), IMAGE_ICON,
      GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON), LR_SHARED));
  wcscpy_s(data.szTip, L"SVOI — открыть приложение");
  return data;
}

std::wstring WideText(const std::string& text) {
  const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
                                        static_cast<int>(text.size()), nullptr, 0);
  if (length <= 0) return L"";
  std::wstring result(length, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
                      static_cast<int>(text.size()), result.data(), length);
  return result;
}

template <typename T>
const T* MenuValue(const flutter::EncodableMap& map, const char* key) {
  auto entry = map.find(flutter::EncodableValue(key));
  return entry == map.end() ? nullptr : std::get_if<T>(&entry->second);
}

HMENU BuildTrayMenu(const flutter::EncodableList& items, UINT& next,
                   std::map<UINT, std::string>& actions, int depth = 0) {
  HMENU menu = CreatePopupMenu();
  if (!menu || depth > 3) return menu;
  for (const auto& value : items) {
    if (next > 128) break;
    const auto* item = std::get_if<flutter::EncodableMap>(&value);
    if (!item) continue;
    const auto* separator = MenuValue<bool>(*item, "separator");
    if (separator && *separator) {
      AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
      continue;
    }
    const auto* label = MenuValue<std::string>(*item, "label");
    if (!label) continue;
    std::wstring text = WideText(*label);
    if (text.size() > 90) text = text.substr(0, 87) + L"…";
    UINT flags = MF_STRING;
    const auto* enabled = MenuValue<bool>(*item, "enabled");
    if (enabled && !*enabled) flags |= MF_GRAYED;
    const auto* checked = MenuValue<bool>(*item, "checked");
    if (checked && *checked) flags |= MF_CHECKED;
    const auto* children = MenuValue<flutter::EncodableList>(*item, "children");
    if (children) {
      HMENU child = BuildTrayMenu(*children, next, actions, depth + 1);
      if (child) AppendMenuW(menu, flags | MF_POPUP, reinterpret_cast<UINT_PTR>(child), text.c_str());
    } else {
      const UINT id = next++;
      const auto* action = MenuValue<std::string>(*item, "id");
      if (action && !action->empty()) actions[id] = *action;
      AppendMenuW(menu, flags, id, text.c_str());
    }
  }
  return menu;
}
}

FlutterWindow::FlutterWindow(const flutter::DartProject& project, bool start_hidden)
    : project_(project), start_hidden_(start_hidden) {}

FlutterWindow::~FlutterWindow() {}

LRESULT FlutterWindow::FrameHitTest(LPARAM position) {
  if (!custom_frame_) return HTCLIENT;
  POINT point{GET_X_LPARAM(position), GET_Y_LPARAM(position)};
  ScreenToClient(GetHandle(), &point);
  RECT client{};
  GetClientRect(GetHandle(), &client);
  const UINT dpi = GetDpiForWindow(GetHandle());
  const int border = GetSystemMetricsForDpi(SM_CXSIZEFRAME, dpi) +
                     GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
  if (!IsZoomed(GetHandle())) {
    const bool left = point.x < border, right = point.x >= client.right - border;
    const bool top = point.y < border, bottom = point.y >= client.bottom - border;
    if (top && left) return HTTOPLEFT;
    if (top && right) return HTTOPRIGHT;
    if (bottom && left) return HTBOTTOMLEFT;
    if (bottom && right) return HTBOTTOMRIGHT;
    if (left) return HTLEFT;
    if (right) return HTRIGHT;
    if (top) return HTTOP;
    if (bottom) return HTBOTTOM;
  }
  const double x = point.x * 96.0 / dpi, y = point.y * 96.0 / dpi;
  const auto contains = [x, y](const TitlebarRect& r) {
    return x >= r.x && y >= r.y && x < r.x + r.width && y < r.y + r.height;
  };
  if (contains(maximize_region_)) return HTMAXBUTTON;
  for (const auto& region : drag_regions_) {
    if (contains(region)) return HTCAPTION;
  }
  return HTCLIENT;
}

void FlutterWindow::CaptionHover(bool hovered) {
  if (max_hovered_ == hovered) return;
  max_hovered_ = hovered;
  if (channel_) channel_->InvokeMethod("captionHover",
      std::make_unique<flutter::EncodableValue>(hovered));
}

LRESULT CALLBACK FlutterWindow::ChildFrameProc(HWND hwnd, UINT message,
    WPARAM wparam, LPARAM lparam, UINT_PTR id, DWORD_PTR context) {
  auto* window = reinterpret_cast<FlutterWindow*>(context);
  if (message == WM_NCHITTEST && window->FrameHitTest(lparam) != HTCLIENT) {
    return HTTRANSPARENT;
  }
  if (message == WM_NCDESTROY) RemoveWindowSubclass(hwnd, ChildFrameProc, id);
  return DefSubclassProc(hwnd, message, wparam, lparam);
}

bool FlutterWindow::UpdateTray() {
  auto data = TrayData(GetHandle());
  wcsncpy_s(data.szTip, tray_tooltip_.c_str(), _TRUNCATE);
  tray_added_ = Shell_NotifyIconW(NIM_MODIFY, &data) || Shell_NotifyIconW(NIM_ADD, &data);
  return tray_added_;
}

void FlutterWindow::RestoreFromTray() {
  ShowWindow(GetHandle(), SW_RESTORE);
  SetForegroundWindow(GetHandle());
  if (channel_) channel_->InvokeMethod("visibility", std::make_unique<flutter::EncodableValue>(true));
}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);

  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "dev.svoi/window",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "ready") {
      dart_ready_ = true;
      channel_->InvokeMethod("windowState",
          std::make_unique<flutter::EncodableValue>(IsZoomed(GetHandle()) != FALSE));
      result->Success();
    } else if (call.method_name() == "titlebar") {
      const auto* geometry = call.arguments() ? std::get_if<flutter::EncodableMap>(call.arguments()) : nullptr;
      const auto read_rect = [](const flutter::EncodableValue& value, TitlebarRect& rect) {
        const auto* values = std::get_if<flutter::EncodableList>(&value);
        if (!values || values->size() != 4) return false;
        double numbers[4]{};
        for (size_t i = 0; i < 4; ++i) {
          if (const auto* number = std::get_if<double>(&(*values)[i])) numbers[i] = *number;
          else return false;
          if (!std::isfinite(numbers[i]) || numbers[i] < 0) return false;
        }
        rect = {numbers[0], numbers[1], numbers[2], numbers[3]};
        return true;
      };
      const auto* drag = geometry ? MenuValue<flutter::EncodableList>(*geometry, "drag") : nullptr;
      if (!drag || drag->size() > 4) { result->Error("frame", "Invalid titlebar"); return; }
      auto max = geometry->find(flutter::EncodableValue("maximize"));
      TitlebarRect maximize{};
      std::vector<TitlebarRect> regions;
      if (max == geometry->end() || !read_rect(max->second, maximize)) {
        result->Error("frame", "Invalid maximize bounds"); return;
      }
      for (const auto& value : *drag) {
        TitlebarRect rect{};
        if (!read_rect(value, rect)) { result->Error("frame", "Invalid drag bounds"); return; }
        regions.push_back(rect);
      }
      maximize_region_ = maximize;
      drag_regions_ = std::move(regions);
      if (!custom_frame_) {
        custom_frame_ = true;
        const MARGINS margins{1, 1, 1, 1};
        DwmExtendFrameIntoClientArea(GetHandle(), &margins);
        SetWindowPos(GetHandle(), nullptr, 0, 0, 0, 0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
      }
      result->Success();
    } else if (call.method_name() == "minimize") {
      ShowWindow(GetHandle(), SW_MINIMIZE);
      result->Success();
    } else if (call.method_name() == "maximize") {
      ShowWindow(GetHandle(), IsZoomed(GetHandle()) ? SW_RESTORE : SW_MAXIMIZE);
      result->Success();
    } else if (call.method_name() == "requestWindowClose") {
      PostMessage(GetHandle(), WM_CLOSE, 0, 0);
      result->Success();
    } else if (call.method_name() == "close") {
      allow_close_ = true;
      KillTimer(GetHandle(), 1);
      result->Success();
      PostMessage(GetHandle(), WM_CLOSE, 0, 0);
    } else if (call.method_name() == "show") {
      RestoreFromTray();
      result->Success();
    } else if (call.method_name() == "openExternal") {
      const auto* url = call.arguments() ? std::get_if<std::string>(call.arguments()) : nullptr;
      if (!url || !IsExternalHttpsUrl(*url)) {
        result->Error("url", "Недопустимая ссылка");
        return;
      }
      const auto wide = WideText(*url);
      const auto opened = reinterpret_cast<INT_PTR>(ShellExecuteW(GetHandle(), L"open", wide.c_str(), nullptr, nullptr, SW_SHOWNORMAL));
      if (opened > 32) result->Success();
      else result->Error("url", "Не удалось открыть браузер");
    } else if (call.method_name() == "openCommunity") {
      wchar_t association[1024]{};
      DWORD length = static_cast<DWORD>(std::size(association));
      if (FAILED(AssocQueryStringW(ASSOCF_IS_PROTOCOL, ASSOCSTR_PROGID,
          L"tg", nullptr, association, &length)) || association[0] == L'\0') {
        result->Error("telegram_missing", "Telegram не установлен или ссылки tg: не зарегистрированы");
        return;
      }
      SHELLEXECUTEINFOW launch{};
      launch.cbSize = sizeof(launch);
      launch.fMask = SEE_MASK_FLAG_NO_UI;
      launch.hwnd = GetHandle();
      launch.lpVerb = L"open";
      launch.lpFile = L"tg://resolve?domain=SVOI_client";
      launch.nShow = SW_SHOWNORMAL;
      if (ShellExecuteExW(&launch)) result->Success();
      else result->Error("telegram_launch", "Не удалось открыть Telegram");
    } else if (call.method_name() == "updateTray") {
      const auto* state = call.arguments() ? std::get_if<flutter::EncodableMap>(call.arguments()) : nullptr;
      if (!state) {
        result->Error("tray", "Неверное состояние меню трея");
        return;
      }
      if (const auto* text = MenuValue<std::string>(*state, "tooltip")) tray_tooltip_ = WideText(*text);
      if (const auto* items = MenuValue<flutter::EncodableList>(*state, "items")) tray_items_ = *items;
      if (UpdateTray()) result->Success();
      else result->Error("tray", "Не удалось обновить значок в трее");
    } else if (call.method_name() == "tray") {
      if (!UpdateTray()) {
        result->Error("tray", "Не удалось создать значок в трее");
        return;
      }
      ShowWindow(GetHandle(), SW_HIDE);
      channel_->InvokeMethod("visibility", std::make_unique<flutter::EncodableValue>(false));
      result->Success();
    } else if (call.method_name() == "openFile" || call.method_name() == "openExe" || call.method_name() == "saveFile") {
      wchar_t path[32768] = {};
      const bool save = call.method_name() == "saveFile";
      if (save && call.arguments()) {
        if (auto name = std::get_if<std::string>(call.arguments())) {
          MultiByteToWideChar(CP_UTF8, 0, name->c_str(), -1, path, 32768);
        }
      }
      OPENFILENAMEW dialog{};
      dialog.lStructSize = sizeof(dialog);
      dialog.hwndOwner = GetHandle();
      dialog.lpstrFile = path;
      dialog.nMaxFile = 32768;
      dialog.lpstrFilter = call.method_name() == "openExe" ? L"Приложения (*.exe)\0*.exe\0\0" : L"Профили и конфигурации\0*.svoi;*.json;*.txt\0Все файлы\0*.*\0\0";
      dialog.Flags = OFN_EXPLORER | OFN_NOCHANGEDIR | OFN_PATHMUSTEXIST | (save ? OFN_OVERWRITEPROMPT : OFN_FILEMUSTEXIST);
      if (save ? GetSaveFileNameW(&dialog) : GetOpenFileNameW(&dialog)) {
        result->Success(flutter::EncodableValue(Utf8FromUtf16(path)));
      } else if (CommDlgExtendedError() != 0) {
        result->Error("file_dialog", "Не удалось открыть диалог файла");
      } else {
        result->Success();
      }
    } else {
      result->NotImplemented();
    }
  });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  SetWindowSubclass(flutter_controller_->view()->GetNativeWindow(), ChildFrameProc,
      1, reinterpret_cast<DWORD_PTR>(this));

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    if (!start_hidden_ || !UpdateTray()) this->Show();
  });

  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  auto tray = TrayData(GetHandle());
  Shell_NotifyIconW(NIM_DELETE, &tray);
  channel_ = nullptr;
  if (flutter_controller_) {
    RemoveWindowSubclass(flutter_controller_->view()->GetNativeWindow(), ChildFrameProc, 1);
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (custom_frame_) {
    if (message == WM_NCCALCSIZE && wparam) {
      if (IsZoomed(hwnd)) {
        auto* params = reinterpret_cast<NCCALCSIZE_PARAMS*>(lparam);
        const UINT dpi = GetDpiForWindow(hwnd);
        const int x = GetSystemMetricsForDpi(SM_CXSIZEFRAME, dpi) +
                      GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
        const int y = GetSystemMetricsForDpi(SM_CYSIZEFRAME, dpi) +
                      GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
        InflateRect(&params->rgrc[0], -x, -y);
      }
      return 0;
    }
    if (message == WM_NCHITTEST) return FrameHitTest(lparam);
    if (message == WM_NCMOUSEMOVE) {
      CaptionHover(wparam == HTMAXBUTTON);
      TRACKMOUSEEVENT tracking{sizeof(tracking), TME_LEAVE | TME_NONCLIENT, hwnd, 0};
      TrackMouseEvent(&tracking);
      LRESULT result = 0;
      if (DwmDefWindowProc(hwnd, message, wparam, lparam, &result)) return result;
    }
    if (message == WM_NCMOUSELEAVE) CaptionHover(false);
    if (message == WM_NCLBUTTONDOWN && wparam == HTMAXBUTTON) {
      max_pressed_ = true;
      SetCapture(hwnd);
      return 0;
    }
    if (message == WM_LBUTTONUP && max_pressed_) {
      max_pressed_ = false;
      POINT point{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      ClientToScreen(hwnd, &point);
      const bool activate = FrameHitTest(MAKELPARAM(point.x, point.y)) == HTMAXBUTTON;
      ReleaseCapture();
      CaptionHover(false);
      if (activate) ShowWindow(hwnd, IsZoomed(hwnd) ? SW_RESTORE : SW_MAXIMIZE);
      return 0;
    }
    if (message == WM_CAPTURECHANGED) max_pressed_ = false;
  }
  if (message == WM_DESTROY) {
    auto data = TrayData(hwnd);
    Shell_NotifyIconW(NIM_DELETE, &data);
  }
  if (message == kTaskbarCreated && tray_added_) {
    if (!UpdateTray() && !IsWindowVisible(hwnd)) RestoreFromTray();
  }
  if (message == kTrayMessage) {
    if (lparam == WM_LBUTTONUP || lparam == WM_LBUTTONDBLCLK) {
      RestoreFromTray();
    } else if (lparam == WM_RBUTTONUP) {
      UINT next = 1;
      std::map<UINT, std::string> actions;
      HMENU menu = BuildTrayMenu(tray_items_, next, actions);
      if (!menu) return 0;
      if (tray_items_.empty()) {
        AppendMenuW(menu, MF_STRING, next, L"Открыть SVOI");
        actions[next++] = "open";
        AppendMenuW(menu, MF_STRING, next, L"Отключить и выйти");
        actions[next] = "quit";
      }
      SetMenuDefaultItem(menu, 0, TRUE);
      POINT point{};
      GetCursorPos(&point);
      SetForegroundWindow(hwnd);
      const int command = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, point.x, point.y, 0, hwnd, nullptr);
      DestroyMenu(menu);
      PostMessage(hwnd, WM_NULL, 0, 0);
      auto found = actions.find(command);
      if (found != actions.end()) {
        if (found->second == "open") RestoreFromTray();
        else if (found->second == "quit") PostMessage(hwnd, WM_CLOSE, 0, 0);
        else if (channel_) {
          channel_->InvokeMethod("trayAction", std::make_unique<flutter::EncodableValue>(found->second));
        }
      }
    }
    return 0;
  }
  if (message == WM_GETMINMAXINFO) {
    auto info = reinterpret_cast<MINMAXINFO*>(lparam);
    const UINT dpi = GetDpiForWindow(hwnd);
    info->ptMinTrackSize.x = MulDiv(800, dpi, 96);
    info->ptMinTrackSize.y = MulDiv(600, dpi, 96);
    return 0;
  }
  if (message == WM_CLOSE && dart_ready_ && !allow_close_) {
    if (!closing_) {
      closing_ = true;

      SetTimer(hwnd, 1, 30000, nullptr);
      channel_->InvokeMethod("requestClose", nullptr);
    }
    return 0;
  }
  if (message == WM_TIMER && wparam == 1) {
    allow_close_ = true;
    KillTimer(hwnd, 1);
    PostMessage(hwnd, WM_CLOSE, 0, 0);
    return 0;
  }
  if (message == WM_SIZE && dart_ready_) {
    channel_->InvokeMethod("windowState",
        std::make_unique<flutter::EncodableValue>(IsZoomed(hwnd) != FALSE));
    channel_->InvokeMethod("visibility", std::make_unique<flutter::EncodableValue>(wparam != SIZE_MINIMIZED));
  }

  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
