#pragma once

#include "device_controls.h"

// Device controls declared by the M5Paper firmware descriptor.
namespace m5paper_controls {
using device_controls::Control;
using device_controls::Kind;
using device_controls::Option;

constexpr uint32_t minimumDelaySeconds = 10;
constexpr uint32_t maximumDelaySeconds = 3600;

static const Option screenSaverOptions[] = {
    {"media", "Library Media"},
    {"geometricSnake", "Geometric Snake"},
};

enum Index : uint8_t {
    slideshow, screenSaver, sleepDelay, slideshowInterval, slideshowSleep, batteryStillImages,
    remoteSleep, lowPowerMode, qualityRefresh,
    battery, temperature, humidity, wifiSignal,
    refreshDisplay, showRemote, nextMedia, previousMedia, sleepNow, restart,
    count
};

static const Control controls[] = {
    {"slideshow", "Screen saver", Kind::toggle, "Screen saver", 0, 0, 0, nullptr, nullptr, 0, false, false},
    {"screenSaver", "Screen saver style", Kind::select, "Screen saver", 0, 0, 0, nullptr,
        screenSaverOptions, 2, false, false},
    {"sleepDelay", "Idle delay", Kind::range, "Screen saver", minimumDelaySeconds,
        maximumDelaySeconds, 10, "s", nullptr, 0, false, false},
    {"slideshowInterval", "Image interval", Kind::range, "Screen saver", minimumDelaySeconds,
        maximumDelaySeconds, 10, "s", nullptr, 0, false, false},
    {"slideshowSleep", "Sleep between images", Kind::toggle, "Screen saver", 0, 0, 0, nullptr,
        nullptr, 0, false, false},
    {"batteryStillImages", "Still images on battery", Kind::toggle, "Screen saver", 0, 0, 0,
        nullptr, nullptr, 0, false, false},
    {"remoteSleep", "Sleep when idle", Kind::toggle, "Power", 0, 0, 0, nullptr, nullptr, 0,
        false, false},
    {"lowPowerMode", "Low Power Mode", Kind::toggle, "Power", 0, 0, 0, nullptr, nullptr, 0,
        true, false},
    {"qualityRefresh", "Quality refresh", Kind::toggle, "Display", 0, 0, 0, nullptr, nullptr, 0,
        false, false},
    {"battery", "Battery", Kind::range, "Status", 0, 100, 1, "%", nullptr, 0, true, false},
    {"temperature", "Temperature", Kind::range, "Status", -40, 125, 0.1, "°C", nullptr, 0, true,
        false},
    {"humidity", "Humidity", Kind::range, "Status", 0, 100, 1, "%", nullptr, 0, true, false},
    {"wifiSignal", "Wi-Fi signal", Kind::range, "Status", -100, 0, 1, "dBm", nullptr, 0, true,
        false},
    {"refreshDisplay", "Refresh display", Kind::action, "Display", 0, 0, 0, nullptr, nullptr, 0,
        false, false},
    {"showRemote", "Show remote", Kind::action, "Display", 0, 0, 0, nullptr, nullptr, 0, false,
        false},
    {"nextMedia", "Next media", Kind::action, "Media", 0, 0, 0, nullptr, nullptr, 0, false, false},
    {"previousMedia", "Previous media", Kind::action, "Media", 0, 0, 0, nullptr, nullptr, 0, false,
        false},
    {"sleepNow", "Sleep now", Kind::action, "Power", 0, 0, 0, nullptr, nullptr, 0, false, false},
    {"restart", "Restart", Kind::action, "Power", 0, 0, 0, nullptr, nullptr, 0, false, true},
};
static_assert(sizeof(controls) / sizeof(controls[0]) == count, "control table order");
}  // namespace m5paper_controls
