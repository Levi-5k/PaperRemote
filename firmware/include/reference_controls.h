#pragma once

#include "device_controls.h"

// Device controls declared by the screenless reference firmware descriptor.
namespace reference_controls {
using device_controls::Control;
using device_controls::Kind;

enum Index : uint8_t { wifiConnected, wifiSignal, restart,
#if defined(PAPERGIF_SUPERMINI_S3)
    dialPresent, dialPosition, dialAngle, dialOutput, dialMode, dialStart, dialSweep, dialTurns,
    dialStep, dialJitter, dialLowLatency, dialRate, dialZero,
#endif
    count };

#if defined(PAPERGIF_SUPERMINI_S3)
static const device_controls::Option dialModes[] = {
    {"single", "Bounded single turn"}, {"multi", "Bounded multi-turn"},
    {"continuous", "Continuous relative"},
};
#endif

static const Control controls[] = {
    {"wifiConnected", "Wi-Fi connected", Kind::toggle, "Status", 0, 0, 0, nullptr, nullptr, 0,
        true, false},
    {"wifiSignal", "Wi-Fi signal", Kind::range, "Status", -100, 0, 1, "dBm", nullptr, 0, true,
        false},
    {"restart", "Restart", Kind::action, "Device", 0, 0, 0, nullptr, nullptr, 0, false, true},
#if defined(PAPERGIF_SUPERMINI_S3)
    {"dialPresent", "Dial sensor connected", Kind::toggle, "Dial", 0, 0, 0, nullptr, nullptr, 0, true, false},
    {"dialPosition", "Live position", Kind::range, "Dial", -1e12, 1e12, 0.01, "deg", nullptr, 0, true, false},
    {"dialAngle", "Shaft angle", Kind::range, "Dial", 0, 360, 0.01, "deg", nullptr, 0, true, false},
    {"dialOutput", "Dial output", Kind::range, "Dial", -1e12, 1e12, 0.01, "%", nullptr, 0, true, false},
    {"dialMode", "Rotation mode", Kind::select, "Dial", 0, 0, 0, nullptr, dialModes, 3, false, false},
    {"dialStart", "Start angle", Kind::range, "Dial", 0, 359.9, 0.1, "deg", nullptr, 0, false, false},
    {"dialSweep", "Single-turn end stop", Kind::range, "Dial", -360, 360, 0.1, "deg", nullptr, 0, false, false},
    {"dialTurns", "Multi-turn end stop", Kind::range, "Dial", -100, 100, 0.1, "rev", nullptr, 0, false, false},
    {"dialStep", "Output resolution", Kind::range, "Dial", 0.01, 10, 0.01, "%", nullptr, 0, false, false},
    {"dialJitter", "Jitter filter", Kind::range, "Dial", 0, 5, 0.01, "deg", nullptr, 0, false, false},
    {"dialLowLatency", "Low latency mode", Kind::toggle, "Dial", 0, 0, 0, nullptr, nullptr, 0, false, false},
    {"dialRate", "Low latency rate", Kind::range, "Dial", 15, 500, 1, "/s", nullptr, 0, false, false},
    {"dialZero", "Set current position to start", Kind::action, "Dial", 0, 0, 0, nullptr, nullptr, 0, false, false},
#endif
};

static_assert(sizeof(controls) / sizeof(controls[0]) == count, "control table out of sync");
}  // namespace reference_controls
