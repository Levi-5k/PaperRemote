#pragma once

#include "reference_profile.h"
#include "media_timeline.h"
#include "remote_button_texture.h"
#include <string>

namespace paper_board {
constexpr size_t maxPageTiles = 24;
constexpr int pageHeaderHeight = 28;

struct MediaSynchronization {
    uint32_t epoch = 0, pollAt = 0, updatedAt = 0;

    std::string subscriptionID(uint32_t generation, int computer) const {
        return "media-" + std::to_string(generation) + "-" + std::to_string(computer + 1);
    }
    void command(uint32_t now) {
        ++epoch;
        const uint32_t refreshAt = now + 350;
        if (int32_t(pollAt - refreshAt) > 0) pollAt = refreshAt;
    }
    bool acceptsPoll(uint32_t requestedEpoch, uint32_t startedAt) const {
        return requestedEpoch == epoch && int32_t(startedAt - updatedAt) >= 0;
    }
};

struct PageMediaState {
    media_timeline::State timeline;
    char text[256]{};
    uint32_t trackRevision = 0;
    uint32_t seekHoldUntil = 0;
    uint32_t knobSeekBlockedUntil = 0;

    void noteLocalSeek(uint32_t now) { seekHoldUntil = now + 5000; }
    void noteTrackChange(uint32_t now) { knobSeekBlockedUntil = now + 5000; }

    bool ignoresKnobSeek(uint32_t now) const {
        return !timeline.available || timeline.stale ||
            (knobSeekBlockedUntil && int32_t(knobSeekBlockedUntil - now) > 0) ||
            (timeline.playing && timeline.durationMilliseconds &&
             media_timeline::elapsedAt(timeline, now) >= timeline.durationMilliseconds);
    }

    void adopt(PageMediaState& next) {
        next.trackRevision = trackRevision + (std::strcmp(text, next.text) != 0 ||
            timeline.available != next.timeline.available ||
            timeline.durationMilliseconds != next.timeline.durationMilliseconds);
        next.seekHoldUntil = int32_t(seekHoldUntil - next.timeline.sampledAt) > 0 ? seekHoldUntil : 0;
        next.knobSeekBlockedUntil = next.trackRevision != trackRevision
            ? next.timeline.sampledAt + 1000 : knobSeekBlockedUntil;
        *this = next;
    }

    bool retainLocalSeek(bool incomingAvailable, uint32_t now) {
        if (incomingAvailable || !timeline.available || int32_t(seekHoldUntil - now) <= 0) return false;
        timeline.sampledAt = now;
        timeline.stale = false;
        return true;
    }

    bool updateItems(JsonVariantConst response, const char* expectedID, uint32_t now) {
        for (JsonObjectConst item : response["items"].as<JsonArrayConst>())
            if (!std::strcmp(expectedID, item["id"] | "")) return update(item, now);
        return false;
    }

    bool update(JsonObjectConst response, uint32_t now) {
        if (!response["available"].is<bool>()) return false;
        PageMediaState next;
        const bool available = response["available"];
        next.timeline.available = available && response["elapsedMilliseconds"].is<uint32_t>() &&
            response["durationMilliseconds"].is<uint32_t>() && response["durationMilliseconds"].as<uint32_t>() > 0;
        if (next.timeline.available) {
            next.timeline.durationMilliseconds = response["durationMilliseconds"];
            next.timeline.elapsedMilliseconds = std::min(response["elapsedMilliseconds"].as<uint32_t>(),
                next.timeline.durationMilliseconds);
            next.timeline.playing = response["playing"] | false;
        }
        next.timeline.stale = !next.timeline.available;
        next.timeline.sampledAt = now;
        if (retainLocalSeek(next.timeline.available, now)) return true;
        const char* title = available ? response["text"] | "" : "";
        if (std::strlen(title) >= sizeof(next.text)) return false;
        std::strcpy(next.text, title);
        adopt(next);
        return true;
    }

    bool updatePhone(const uint8_t* bytes, size_t length, uint32_t now) {
        if (length < 12 || bytes[0] != 0x61 || bytes[11] > 52 || length != size_t(12 + bytes[11])) return false;
        auto read32 = [&](size_t offset) {
            return uint32_t(bytes[offset]) | uint32_t(bytes[offset + 1]) << 8 |
                uint32_t(bytes[offset + 2]) << 16 | uint32_t(bytes[offset + 3]) << 24;
        };
        PageMediaState next;
        next.timeline.durationMilliseconds = read32(7);
        next.timeline.available = (bytes[1] & 1) && next.timeline.durationMilliseconds > 0;
        next.timeline.playing = (bytes[1] & 2) != 0;
        next.timeline.elapsedMilliseconds = std::min(read32(3), next.timeline.durationMilliseconds);
        next.timeline.stale = !next.timeline.available;
        next.timeline.sampledAt = now;
        if (retainLocalSeek(next.timeline.available, now)) return true;
        if (bytes[1] & 1) std::memcpy(next.text, bytes + 12, bytes[11]);
        adopt(next);
        return true;
    }
};

inline bool rebaseSeekBinding(HardwareBinding& binding, const PageMediaState& media, uint32_t now) {
    if (!media.timeline.available || !media.timeline.durationMilliseconds) return false;
    if (binding.hasLocalValue && binding.mediaTrackRevision == media.trackRevision &&
        (now - binding.localValueAt < 3000 ||
         int32_t(media.timeline.sampledAt - binding.localValueAt) <= 0)) return false;
    const double percent = double(media_timeline::elapsedAt(media.timeline, now)) * 100 /
        media.timeline.durationMilliseconds;
    binding.state.value = boundValue(percent, binding.state);
    binding.state.remainder = 0;
    binding.localValueAt = now;
    binding.hasLocalValue = true;
    binding.mediaTrackRevision = media.trackRevision;
    return true;
}

struct WaveshareUiState {
    bool configured = false;
    JsonDocument* profile = nullptr;
    size_t pageIndex = 0;
    uint32_t profileRevision = 0;
    bool (*controlEvent)(size_t, const char*, double) = nullptr;
    void (*changePage)(int) = nullptr;
    const PageMediaState* (*mediaState)(const NativeAction&) = nullptr;
    uint32_t now = 0;
    uint32_t imageRevision = 0;
    bool screensaver = false;
    const uint8_t* screenImage = nullptr;
    void (*activity)() = nullptr;
    remote_button_texture::ImageView (*buttonImage)(const char*) = nullptr;
};

struct PageTilePlacement {
    int slot = -1;
    int width = 1;
    int height = 1;
};

inline bool layoutPageTiles(JsonObjectConst page, PageTilePlacement* placements) {
    const int columns = page["gridColumns"] | 2;
    const int rows = page["gridRows"] | 8;
    const auto controls = page["controls"].as<JsonArrayConst>();
    if (columns < 1 || columns > 12 || rows < 1 || rows > 16 || controls.size() > maxPageTiles) return false;
    bool occupied[192]{};
    for (size_t index = 0; index < controls.size(); ++index) {
        auto& placement = placements[index];
        placement = PageTilePlacement{};
        const auto tile = controls[index];
        const char* kind = tile["kind"] | "button";
        const bool text = !std::strcmp(kind, "textBox");
        const int defaultWidth = text ? std::clamp(tile["textBox"]["gridWidth"] | 2, 1, 2) : 1;
        const int defaultHeight = text ? std::clamp(tile["textBox"]["gridHeight"] | 1, 1, 8) :
            !std::strcmp(kind, "button") ? std::clamp(tile["buttonHeight"] | 2, 1, 2) : 1;
        placement.width = std::clamp(tile["gridWidth"] | defaultWidth, 1, columns);
        placement.height = std::clamp(tile["gridHeight"] | defaultHeight, 1, rows);
    }
    auto place = [&](size_t index, int slot) {
        auto& tile = placements[index];
        if (slot < 0 || slot >= columns * rows || slot % columns + tile.width > columns ||
            slot / columns + tile.height > rows) return false;
        for (int row = 0; row < tile.height; ++row)
            for (int column = 0; column < tile.width; ++column)
                if (occupied[slot + row * columns + column]) return false;
        for (int row = 0; row < tile.height; ++row)
            for (int column = 0; column < tile.width; ++column)
                occupied[slot + row * columns + column] = true;
        tile.slot = slot;
        return true;
    };
    for (size_t index = 0; index < controls.size(); ++index)
        place(index, controls[index]["layoutSlot"] | -1);
    for (size_t index = 0; index < controls.size(); ++index) {
        if (placements[index].slot >= 0) continue;
        for (int slot = 0; slot < columns * rows; ++slot)
            if (place(index, slot)) break;
        if (placements[index].slot < 0) return false;
    }
    return true;
}

inline Rect pageTileRect(const PageTilePlacement& tile, int columns, int rows, int width, int height) {
    if (tile.slot < 0 || columns < 1 || rows < 1 || height <= pageHeaderHeight) return {};
    const double contentHeight = height - pageHeaderHeight;
    const double cellWidth = width * 0.92 / columns;
    const double cellHeight = contentHeight * 0.92 / rows;
    return {width * 0.04 + tile.slot % columns * cellWidth,
        pageHeaderHeight + contentHeight * 0.04 + tile.slot / columns * cellHeight,
        cellWidth * tile.width - 2, cellHeight * tile.height - 2};
}

inline BindingState tileSliderState(const NativeAction& action) {
    BindingState state;
    state.mode = BindingMode::absolute;
    if (!std::strcmp(action.type, "wledBrightness")) state.maximum = 255;
    if (!std::strcmp(action.type, "netHomeTemperature")) {
        state.minimum = 16;
        state.maximum = 30;
        state.step = 0.5;
    }
    state.value = boundValue(nativeControlValue(action), state);
    return state;
}

inline bool validTouchPages(JsonDocument& json) {
    for (JsonObjectConst page : json["pages"].as<JsonArrayConst>()) {
        if (!page["id"].is<const char*>() || std::strlen(page["id"] | "") >= 40) return false;
        PageTilePlacement placements[maxPageTiles];
        if (!layoutPageTiles(page, placements)) return false;
        for (JsonObjectConst tile : page["controls"].as<JsonArrayConst>()) {
            if (!tile["id"].is<const char*>() || std::strlen(tile["id"] | "") >= 40) return false;
            const char* kind = tile["kind"] | "";
            if (!std::strcmp(kind, "textBox")) {
                if (std::strcmp(tile["textBox"]["source"] | "staticText", "staticText") ||
                    std::strcmp(tile["textBox"]["tapBehavior"] | "displayOnly", "displayOnly")) return false;
                continue;
            }
            if (std::strcmp(kind, "button") && std::strcmp(kind, "slider")) return false;
            NativeAction action;
            if (!parseAction(tile["action"], action)) return false;
            if (!std::strcmp(kind, "slider") && !adjustableAction(action)) return false;
        }
    }
    return true;
}

struct PageSwipe {
    bool down = false;
    bool slider = false;
    bool swiped = false;
    int startX = 0, startY = 0;
    void begin(int x, int y, bool onSlider) {
        down = true;
        slider = onSlider;
        swiped = false;
        startX = x;
        startY = y;
    }
    int move(int x, int y) {
        const int horizontal = x - startX;
        const int vertical = y - startY;
        if (down && !slider && std::abs(horizontal) >= 48 &&
            std::abs(horizontal) > std::abs(vertical) * 1.4) {
            swiped = true;
            return horizontal < 0 ? 1 : -1;
        }
        return 0;
    }
};
}