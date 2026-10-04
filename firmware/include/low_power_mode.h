#pragma once

#include <stdint.h>

namespace low_power_mode {
constexpr int enterBelowPercent = 30;
constexpr int exitAtPercent = 35;
constexpr uint32_t maximumIdleDelayMs = 60000;
constexpr uint32_t minimumRefreshIntervalMs = 60000;
constexpr uint32_t mediaClockStepSeconds = 30;

// Hysteresis keeps load-induced voltage sag from toggling the mode. Unknown
// readings keep the current mode.
constexpr bool next(bool active, int batteryPercent) {
    return batteryPercent < 0 ? active
        : active ? batteryPercent < exitAtPercent
        : batteryPercent < enterBelowPercent;
}

constexpr uint32_t idleDelayMs(bool active, uint32_t delayMs) {
    return active && delayMs > maximumIdleDelayMs ? maximumIdleDelayMs : delayMs;
}

// Zero means "never refresh" and is preserved.
constexpr uint32_t refreshIntervalMs(bool active, uint32_t intervalMs) {
    return active && intervalMs > 0 && intervalMs < minimumRefreshIntervalMs
        ? minimumRefreshIntervalMs : intervalMs;
}
}  // namespace low_power_mode
