#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>

namespace media_timeline {

struct State {
    bool available = false;
    bool playing = false;
    bool stale = true;
    uint32_t elapsedMilliseconds = 0;
    uint32_t durationMilliseconds = 0;
    uint32_t sampledAt = 0;
};

inline uint32_t elapsedAt(const State& state, uint32_t now) {
    const uint64_t elapsed = static_cast<uint64_t>(state.elapsedMilliseconds) +
        (state.available && state.playing && !state.stale
            ? static_cast<uint32_t>(now - state.sampledAt) : 0);
    return elapsed < state.durationMilliseconds
        ? static_cast<uint32_t>(elapsed) : state.durationMilliseconds;
}

struct Position {
    bool available = false;
    uint32_t elapsedSeconds = 0;
    uint32_t durationSeconds = 0;

    bool operator==(const Position& other) const {
        return available == other.available && elapsedSeconds == other.elapsedSeconds &&
            durationSeconds == other.durationSeconds;
    }
    bool operator!=(const Position& other) const { return !(*this == other); }
};

// Works with RemoteControl as well as small host-test controls. Prefer the
// dragged seek slider, then a seek slider, then transport-only play/pause.
// Never use the desktop timeline for iPhone controls (or vice versa).
template <typename Control>
Position positionForControls(
    const Control* controls, size_t count, const State& desktop, const State& phone,
    int activeControl, uint32_t now) {
    Position position;
    int selectedPriority = -1;
    for (size_t index = 0; index < count; ++index) {
        const Control& control = controls[index];
        const bool seek = control.slider && std::strcmp(control.action.text, "seek") == 0;
        const bool playback = control.kind == 0 &&
            std::strcmp(control.action.text, "playPause") == 0;
        if (!seek && !playback) {
            continue;
        }
        const State* state = nullptr;
        if (std::strcmp(control.action.type, "macMedia") == 0) {
            state = &desktop;
        } else if (std::strcmp(control.action.type, "iPhoneMedia") == 0) {
            state = &phone;
        }
        if (state == nullptr || !state->available || state->durationMilliseconds == 0) {
            continue;
        }
        const bool dragging = seek && activeControl == static_cast<int>(index);
        const int priority = dragging ? 2 : seek ? 1 : 0;
        if (priority <= selectedPriority) {
            continue;
        }
        selectedPriority = priority;
        const int value = control.action.value < 0 ? 0
            : control.action.value > 255 ? 255 : control.action.value;
        // Only a user drag uses the quantized slider value. Normal playback time
        // comes from milliseconds, so long tracks still tick every second.
        const uint32_t elapsed = dragging
            ? static_cast<uint64_t>(state->durationMilliseconds) * value / 255
            : elapsedAt(*state, now);
        position.available = true;
        position.elapsedSeconds = elapsed / 1000;
        position.durationSeconds = state->durationMilliseconds / 1000;
    }
    return position;
}

}  // namespace media_timeline