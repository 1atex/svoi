#include "../runner/elevation.h"
#include "../runner/external_url.h"
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
  expect(IsExternalHttpsUrl("https://t.me/Support_bot"), "public HTTPS link");
  expect(IsLocalTelegramProxyUrl("tg://proxy?server=127.0.0.1&port=1443&secret=dd0123456789abcdef0123456789abcdef"), "local Telegram proxy");
  for (const auto* url : {"tg://proxy?server=evil.test&port=1443&secret=dd0123456789abcdef0123456789abcdef", "tg://proxy?server=127.0.0.1&port=99999&secret=dd0123456789abcdef0123456789abcdef", "tg://proxy?server=127.0.0.1&port=1443&secret=dd0123456789abcdef0123456789abcdef&x=1", "https://t.me/proxy"}) {
    expect(!IsLocalTelegramProxyUrl(url), "reject nonlocal or malformed Telegram proxy link");
  }
  for (const auto* url : {"file:///C:/Windows", "https://", "https://user:pass@host", "https://host\\bad", "https://host\n", "javascript:alert(1)"}) {
    expect(!IsExternalHttpsUrl(url), "reject non-public external link");
  }
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
