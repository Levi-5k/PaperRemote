#pragma once

#include <stdint.h>
#include <string.h>

namespace local_http {

inline bool isPrivateIPv4(uint8_t first, uint8_t second) {
    return first == 10 || first == 127 ||
        (first == 169 && second == 254) ||
        (first == 172 && second >= 16 && second <= 31) ||
        (first == 192 && second == 168);
}

inline bool isLocalHostname(const char* host) {
    if (host == nullptr) {
        return false;
    }
    const size_t length = strlen(host);
    return length > 6 && strcmp(host + length - 6, ".local") == 0;
}

inline bool isAllowedMethod(const char* method) {
    return method != nullptr &&
        (strcmp(method, "GET") == 0 || strcmp(method, "POST") == 0);
}

inline bool isAllowedPath(const char* path) {
    return path != nullptr && path[0] == '/' &&
        strchr(path, '\r') == nullptr && strchr(path, '\n') == nullptr &&
        strchr(path, '#') == nullptr && strstr(path, "://") == nullptr;
}

} // namespace local_http