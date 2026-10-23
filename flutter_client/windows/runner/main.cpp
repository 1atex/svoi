#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <algorithm>

#include "flutter_window.h"
#include "utils.h"
#include "elevation.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {

  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  if (HWND previous = FindWindowW(nullptr, L"SVOI")) {
    ShowWindow(previous, SW_RESTORE);
    SetForegroundWindow(previous);
    return EXIT_SUCCESS;
  }
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  if (RelaunchElevatedIfRequested(command_line, show_command)) {
    ::CoUninitialize();
    return EXIT_SUCCESS;
  }
  HANDLE instance_mutex = CreateMutexW(nullptr, FALSE, L"Local\\SVOI.FlutterDesktop");
  if (instance_mutex && GetLastError() == ERROR_ALREADY_EXISTS) {
    HWND previous = FindWindowW(nullptr, L"SVOI");
    if (previous) { ShowWindow(previous, SW_RESTORE); SetForegroundWindow(previous); }
    CloseHandle(instance_mutex);
    ::CoUninitialize();
    return EXIT_SUCCESS;
  }

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  const bool start_hidden = std::find(command_line_arguments.begin(), command_line_arguments.end(), "--startup") != command_line_arguments.end();
  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project, start_hidden);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1240, 900);
  if (!window.Create(L"SVOI", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  if (instance_mutex) CloseHandle(instance_mutex);
  return EXIT_SUCCESS;
}
