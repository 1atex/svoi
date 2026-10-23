#include "elevation.h"
#include <shellapi.h>
#include <vector>

bool WantsAdminLaunch(const std::wstring& executable) {
  const auto slash = executable.find_last_of(L"\\/");
  if (slash == std::wstring::npos) return false;
  const auto ini = executable.substr(0, slash + 1) + L"launch.ini";
  return GetPrivateProfileIntW(L"Launch", L"RunAsAdmin", 0, ini.c_str()) == 1;
}

bool RelaunchElevatedIfRequested(const wchar_t* arguments, int show_command) {
  std::vector<wchar_t> path(32768);
  const DWORD length = GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
  if (!length || length >= path.size()) return false;
  const std::wstring executable(path.data(), length);
  if (!WantsAdminLaunch(executable)) return false;

  HANDLE token = nullptr;
  TOKEN_ELEVATION elevation{};
  DWORD size = sizeof(elevation);
  const bool opened = OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token) != FALSE;
  const bool queried = opened && GetTokenInformation(token, TokenElevation, &elevation, size, &size);
  if (token) CloseHandle(token);
  if (!queried) {
    MessageBoxW(nullptr, L"Не удалось проверить права процесса. Попробуйте запустить SVOI снова.", L"SVOI", MB_OK | MB_ICONERROR);
    return true;
  }
  if (elevation.TokenIsElevated) return false;

  const auto directory = executable.substr(0, executable.find_last_of(L"\\/"));
  SHELLEXECUTEINFOW launch{};
  launch.cbSize = sizeof(launch);
  launch.fMask = SEE_MASK_NOASYNC | SEE_MASK_FLAG_NO_UI;
  launch.lpVerb = L"runas";
  launch.lpFile = executable.c_str();
  launch.lpParameters = arguments;
  launch.lpDirectory = directory.c_str();
  launch.nShow = show_command;
  if (ShellExecuteExW(&launch)) return true;
  if (GetLastError() == ERROR_CANCELLED) {
    return MessageBoxW(nullptr,
        L"Запуск от имени администратора отменён. Открыть SVOI без повышения прав?\n\nTUN и zapret потребуют прав администратора.",
        L"SVOI", MB_YESNO | MB_ICONQUESTION | MB_DEFBUTTON2) != IDYES;
  }
  MessageBoxW(nullptr, L"Windows не удалось запустить SVOI от имени администратора. Повторите запуск или измените этот параметр в установщике.", L"SVOI", MB_OK | MB_ICONERROR);
  return true;
}
