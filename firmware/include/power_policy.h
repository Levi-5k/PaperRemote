#pragma once

#include <stdint.h>

namespace power_policy {
constexpr uint32_t homeWifiRetryMinimumMs = 30000;
constexpr uint32_t homeWifiRetryMaximumMs = 5UL * 60UL * 1000UL;

// Unattended retries back off; any remote activity since the last attempt
// restores the original 30 s cadence for the next one.
constexpr uint32_t homeWifiRetryIntervalMs(
    bool lowPowerMode, bool activitySinceAttempt, uint32_t backoffMs) {
    return lowPowerMode ? homeWifiRetryMaximumMs
        : activitySinceAttempt ? homeWifiRetryMinimumMs
        : backoffMs;
}

constexpr uint32_t nextHomeWifiBackoffMs(uint32_t backoffMs) {
    return backoffMs >= homeWifiRetryMaximumMs / 2 ? homeWifiRetryMaximumMs : backoffMs * 2;
}

// Transmit power in the ESP32's 0.25 dBm units. Downlink RSSI stands in for
// the uplink margin; the reduced levels still leave the access point well
// above typical sensitivity. Unknown RSSI (0) and the transfer access point
// keep full power.
constexpr int8_t wifiTxPowerQuarterDbm(int rssi, bool accessPointActive) {
    return accessPointActive || rssi == 0 || rssi < -60 ? 78
        : rssi < -50 ? 60
        : 44;
}

inline uint32_t ssidHash(const char* ssid) {
    uint32_t hash = 2166136261UL;
    for (; *ssid != '\0'; ++ssid) {
        hash = (hash ^ static_cast<uint8_t>(*ssid)) * 16777619UL;
    }
    return hash;
}
}  // namespace power_policy
