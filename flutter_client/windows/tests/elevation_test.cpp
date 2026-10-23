#include "../runner/elevation.h"
#include <iostream>

int wmain() {
  wchar_t temp[MAX_PATH]{}, unique[MAX_PATH]{};
  if (!GetTempPathW(MAX_PATH, temp) || !GetTempFileNameW(temp, L"svt", 0, unique)) return 1;
  DeleteFileW(unique);
  const std::wstring directory = std::wstring(unique) + L" пробелы";
  if (!CreateDirectoryW(directory.c_str(), nullptr)) return 1;
  const auto executable = directory + L"\\svoi_flutter.exe";
  const auto ini = directory + L"\\launch.ini";
  int failed = 0;
  const auto expect = [&failed](bool ok, const char* label) {
    if (!ok) { std::cerr << label << "\n"; ++failed; }
  };
  expect(!WantsAdminLaunch(executable), "portable without launch.ini must remain unelevated");
  expect(WritePrivateProfileStringW(L"Launch", L"RunAsAdmin", L"1", ini.c_str()) != FALSE, "write enabled fixture");
  expect(WantsAdminLaunch(executable), "installer opt-in must work with unicode and spaces");
  expect(!WantsAdminLaunch(directory + L"\\other\\svoi_flutter.exe"), "preference must be scoped to executable directory");
  WritePrivateProfileStringW(L"Launch", L"RunAsAdmin", L"0", ini.c_str());
  expect(!WantsAdminLaunch(executable), "unchecking on reinstall must disable elevation");
  WritePrivateProfileStringW(L"Launch", L"RunAsAdmin", L"invalid", ini.c_str());
  expect(!WantsAdminLaunch(executable), "invalid preference must not opt in");
  DeleteFileW(ini.c_str());
  RemoveDirectoryW(directory.c_str());
  return failed ? 1 : 0;
}
