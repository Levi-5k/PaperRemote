#pragma once

#include "device_controls.h"

// Device controls declared by the screenless reference firmware descriptor.
namespace reference_controls {
using device_controls::Control;
using device_controls::Kind;

enum Index : uint8_t { wifiConnected, wifiSignal, restart, count };

static const Control controls[] = {
    {"wifiConnected", "Wi-Fi connected", Kind::toggle, "Status", 0, 0, 0, nullptr, nullptr, 0,
        true, false},
    {"wifiSignal", "Wi-Fi signal", Kind::range, "Status", -100, 0, 1, "dBm", nullptr, 0, true,
        false},
    {"restart", "Restart", Kind::action, "Device", 0, 0, 0, nullptr, nullptr, 0, false, true},
};

static_assert(sizeof(controls) / sizeof(controls[0]) == count, "control table out of sync");
}  // namespace reference_controls
