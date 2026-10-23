#include "flutter_window.h"

#include <optional>
#include <flutter/standard_method_codec.h>
#include <commdlg.h>
#include <shellapi.h>
#include "utils.h"
#include "resource.h"

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
}

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

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
    } else if (call.method_name() == "tray") {
      auto data = TrayData(GetHandle());
      if (!Shell_NotifyIconW(NIM_MODIFY, &data) && !Shell_NotifyIconW(NIM_ADD, &data)) {
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
    this->Show();
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
  if (message == kTaskbarCreated && !IsWindowVisible(hwnd)) {
    auto data = TrayData(hwnd);
    if (!Shell_NotifyIconW(NIM_ADD, &data)) ShowWindow(hwnd, SW_RESTORE);
  }
  if (message == kTrayMessage) {
    if (lparam == WM_LBUTTONUP || lparam == WM_LBUTTONDBLCLK) {
      ShowWindow(hwnd, SW_RESTORE);
      SetForegroundWindow(hwnd);
      channel_->InvokeMethod("visibility", std::make_unique<flutter::EncodableValue>(true));
    } else if (lparam == WM_RBUTTONUP) {
      HMENU menu = CreatePopupMenu();
      AppendMenuW(menu, MF_STRING, 1, L"Открыть SVOI");
      AppendMenuW(menu, MF_STRING, 2, L"Отключить и выйти");
      POINT point{};
      GetCursorPos(&point);
      SetForegroundWindow(hwnd);
      const int command = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, point.x, point.y, 0, hwnd, nullptr);
      DestroyMenu(menu);
      if (command == 1) {
        ShowWindow(hwnd, SW_RESTORE);
        channel_->InvokeMethod("visibility", std::make_unique<flutter::EncodableValue>(true));
      }
      if (command == 2) PostMessage(hwnd, WM_CLOSE, 0, 0);
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
