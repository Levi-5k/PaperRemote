#pragma once

#include <stddef.h>
#include <stdint.h>

namespace screensaver_battery {
constexpr size_t noImageIndex = static_cast<size_t>(-1);

// Unknown readings conservatively use stills. Charging alone is not enough.
constexpr bool imagesOnly(bool enabled, int batteryPercent) {
    return enabled && batteryPercent != 100;
}

inline size_t nextImageIndex(
    const uint16_t* frameCounts,
    size_t itemCount,
    size_t startIndex) {
    if (itemCount == 0) {
        return noImageIndex;
    }
    for (size_t offset = 0; offset < itemCount; ++offset) {
        const size_t index = (startIndex + offset) % itemCount;
        if (frameCounts[index] == 1) {
            return index;
        }
    }
    return startIndex % itemCount;
}
}  // namespace screensaver_battery