#pragma once

#include <cstdint>
#include <cstring>

// Button background: a profile-wide default plus an optional per-control override.
namespace remote_button_style {

enum class Background : uint8_t {
    outline = 0,
    filled = 1,
    shaded = 2,
    borderless = 3,
};

// RGB565 (LovyanGFX treats uint32_t colors as RGB888).
constexpr uint16_t kWhite = 0xFFFF;
constexpr uint16_t kBlack = 0x0000;
constexpr uint16_t kShade = 0xC618;

inline bool parse(const char* name, Background& result) {
    if (name == nullptr) return false;
    if (strcmp(name, "outline") == 0) { result = Background::outline; return true; }
    if (strcmp(name, "filled") == 0) { result = Background::filled; return true; }
    if (strcmp(name, "shaded") == 0) { result = Background::shaded; return true; }
    if (strcmp(name, "borderless") == 0) { result = Background::borderless; return true; }
    return false;
}

// Missing or unknown override inherits the system value; unknown system values use outline.
inline Background resolve(const char* systemName, const char* overrideName) {
    Background result = Background::outline;
    if (!parse(overrideName, result)) parse(systemName, result);
    return result;
}

struct Colors {
    uint16_t fill = kWhite;
    uint16_t foreground = kBlack;
    bool border = true;
};

// Active (pressed or toggled on) inverts the idle appearance.
inline Colors colors(Background background, bool active) {
    Colors result;
    if (background == Background::filled) {
        if (!active) {
            result.fill = kBlack;
            result.foreground = kWhite;
            result.border = false;
        }
        return result;
    }
    if (active) {
        result.fill = kBlack;
        result.foreground = kWhite;
        result.border = false;
        return result;
    }
    result.fill = background == Background::shaded ? kShade : kWhite;
    result.border = background == Background::outline;
    return result;
}

}  // namespace remote_button_style
