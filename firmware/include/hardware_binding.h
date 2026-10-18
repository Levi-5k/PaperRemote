#pragma once

#include "board_driver.h"
#include <algorithm>
#include <limits>

namespace paper_board {

enum class BindingMode { action, relative, absolute };
struct BindingState {
    BindingMode mode = BindingMode::action;
    double minimum = 0, maximum = 100, step = 1, value = 0;
    uint32_t sequence = 0;
    bool seen = false;
    bool pressed = false;
    double remainder = 0;
};
inline bool validBinding(const BindingState& b) {
    return std::isfinite(b.minimum) && std::isfinite(b.maximum) &&
        std::isfinite(b.step) && std::isfinite(b.value) && b.minimum < b.maximum &&
        b.minimum >= std::numeric_limits<int32_t>::min() &&
        b.maximum <= std::numeric_limits<int32_t>::max() &&
        b.step > 0 && b.step <= b.maximum - b.minimum;
}
inline double boundValue(double value, const BindingState& b) {
    const double clamped = std::fmax(b.minimum, std::fmin(b.maximum, value));
    const double rounded = b.minimum + std::round((clamped - b.minimum) / b.step) * b.step;
    return std::fmax(b.minimum, std::fmin(b.maximum, rounded));
}
inline bool applyInput(BindingState& state, const InputInfo& input, const InputEvent& event,
                       double& value) {
    if (!validBinding(state) || !std::isfinite(event.value)) return false;
    // Monotonic per-input sequence, with uint32 wrap, rejects stale and duplicate events.
    if (state.seen && static_cast<int32_t>(event.sequence - state.sequence) <= 0) return false;
    state.sequence = event.sequence;
    state.seen = true;
    if (std::strcmp(event.event, "press") == 0) state.pressed = true;
    if (std::strcmp(event.event, "release") == 0) state.pressed = false;
    double next = state.value;
    if (state.mode == BindingMode::relative) {
        if (std::strcmp(event.event, "rotate") != 0) return false;
        // Bound before multiplying so extreme deltas cannot overflow.
        const double delta = std::fmax(-1000000.0, std::fmin(1000000.0, event.value));
        next += delta * state.step;
    } else if (state.mode == BindingMode::absolute) {
        if (std::strcmp(event.event, "change") != 0 || input.maximum <= input.minimum) return false;
        if (event.relative) {
            next += state.remainder + event.value / (input.maximum - input.minimum) *
                (state.maximum - state.minimum);
        } else {
            const double raw = std::fmax(input.minimum, std::fmin(input.maximum, event.value));
            next = state.minimum + (raw - input.minimum) / (input.maximum - input.minimum) *
                (state.maximum - state.minimum);
        }
    }
    state.value = boundValue(next, state);
    state.remainder = event.relative
        ? std::fmax(state.minimum, std::fmin(state.maximum, next)) - state.value : 0;
    value = state.value;
    return true;
}

} // namespace paper_board
