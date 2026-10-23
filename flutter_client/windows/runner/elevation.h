#ifndef SVOI_ELEVATION_H_
#define SVOI_ELEVATION_H_
#include <windows.h>
#include <string>

// Per-installation preference, deliberately not a machine-wide policy.
bool WantsAdminLaunch(const std::wstring& executable);
bool RelaunchElevatedIfRequested(const wchar_t* arguments, int show_command);
#endif
