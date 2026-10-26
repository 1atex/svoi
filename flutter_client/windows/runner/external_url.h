#pragma once

#include <string>

inline bool IsExternalHttpsUrl(const std::string& url) {
  if (url.size() > 2048 || url.rfind("https://", 0) != 0) return false;
  for (const unsigned char c : url) {
    if (c <= 32 || c == 127 || c == '\\') return false;
  }
  const auto authority = url.substr(8, url.find_first_of("/?#", 8) - 8);
  return !authority.empty() && authority.find('@') == std::string::npos;
}
