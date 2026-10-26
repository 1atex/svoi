#include "flutter_window.h"

#include <optional>
#include <map>
#include <flutter/standard_method_codec.h>
#include <commdlg.h>
#include <shellapi.h>
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
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
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
    info->ptMinTrackSize.x = MulDiv(816, dpi, 96);
    info->ptMinTrackSize.y = MulDiv(632, dpi, 96);
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
