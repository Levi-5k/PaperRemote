#pragma once

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>

namespace remote_computer {

constexpr int missing = -2;
constexpr int legacy = -1;

// Computer IDs are UUIDs. Swift and .NET can serialize their hex letters with
// different casing; that must not change the selected computer.
inline bool sameId(const char* left, const char* right) {
    while (*left && *right) {
        const char a = *left >= 'A' && *left <= 'Z' ? *left + ('a' - 'A') : *left;
        const char b = *right >= 'A' && *right <= 'Z' ? *right + ('a' - 'A') : *right;
        if (a != b) return false;
        ++left;
        ++right;
    }
    return *left == *right;
}

template <typename Profile>
int indexFor(const Profile& profile, const char* identifier) {
    if (identifier[0] != '\0') {
        for (size_t index = 0; index < profile.computerCount; ++index) {
            if (sameId(profile.computers[index].id, identifier)) {
                return static_cast<int>(index);
            }
        }
        // An explicitly selected but removed computer must never fall through
        // to another machine, including for playback state queries.
        return missing;
    }
    if (profile.computerCount > 0) return 0;
    return profile.macHost[0] != '\0' && profile.macToken[0] != '\0' ? legacy : missing;
}

template <typename Control>
const char* stateComputerId(const Control& control) {
    // Text boxes may read one computer and run a tap action on another. Media
    // buttons/sliders must read their action target, not leftover text settings.
    return control.kind == 2 && control.textComputerId[0] != '\0'
        ? control.textComputerId : control.action.computerId;
}

template <typename Computer>
bool acceptsToken(const Computer* computer, const char* token) {
    return computer != nullptr && computer->token[0] != '\0' &&
        token != nullptr && std::strcmp(computer->token, token) == 0;
}

template <typename Computer>
bool acceptsResponse(const Computer* computer, const char* url, const char* token) {
    if (!acceptsToken(computer, token)) return false;
    char expected[256];
    const int length = std::snprintf(expected, sizeof(expected), "http://%s:%u/text-source",
        computer->host, static_cast<unsigned>(computer->port));
    return length > 0 && static_cast<size_t>(length) < sizeof(expected) &&
        std::strcmp(expected, url) == 0;
}

}  // namespace remote_computer