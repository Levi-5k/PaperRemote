#pragma once
#include <cstddef>
#include <cstdint>
#include <cstring>

namespace screen_image {
constexpr size_t headerBytes = 10;
inline bool valid(const uint8_t* bytes, size_t length, uint16_t width, uint16_t height) {
    return bytes && width && height && length == headerBytes + size_t(width) * height * 2 &&
        !std::memcmp(bytes, "PIMG", 4) && bytes[4] == 1 && bytes[5] == 0 &&
        (uint16_t(bytes[6]) | uint16_t(bytes[7]) << 8) == width &&
        (uint16_t(bytes[8]) | uint16_t(bytes[9]) << 8) == height;
}
inline uint32_t checksum(const uint8_t* bytes, size_t length) {
    uint32_t result = UINT32_MAX;
    for (size_t index = 0; index < length; ++index) {
        result ^= bytes[index];
        for (int bit = 0; bit < 8; ++bit) result = (result >> 1) ^ (0xedb88320U & (0U - (result & 1)));
    }
    return ~result;
}
}