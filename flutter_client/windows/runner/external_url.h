#pragma once

#include <string>

inline bool IsLocalTelegramProxyUrl(const std::string& url) {
  const std::string prefix = "tg://proxy?server=127.0.0.1&port=";
  if (url.rfind(prefix, 0) != 0) return false;
  const auto divider = url.find("&secret=dd", prefix.size());
  if (divider == std::string::npos) return false;
  const auto port = url.substr(prefix.size(), divider - prefix.size());
  if (port.empty() || port.size() > 5) return false;
  for (char c : port) if (c < '0' || c > '9') return false;
  const int number = std::stoi(port);
  if (number < 1024 || number > 65535) return false;
  const auto secret = url.substr(divider + 10);
  if (secret.size() != 32) return false;
  for (char c : secret) {
    if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
  }
  return true;
}

inline bool IsExternalHttpsUrl(const std::string& url) {
  if (url.size() > 2048 || url.rfind("https://", 0) != 0) return false;
  for (const unsigned char c : url) {
    if (c <= 32 || c == 127 || c == '\\') return false;
  }
  const auto authority = url.substr(8, url.find_first_of("/?#", 8) - 8);
  return !authority.empty() && authority.find('@') == std::string::npos;
}
