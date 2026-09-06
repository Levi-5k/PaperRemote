#pragma once

namespace screensaver_battery {
// Unknown readings conservatively use stills. Charging alone is not enough.
constexpr bool imagesOnly(bool enabled, int batteryPercent) {
    return enabled && batteryPercent != 100;
}
}  // namespace screensaver_battery