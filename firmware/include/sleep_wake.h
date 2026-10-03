#pragma once

#include <stdint.h>

namespace sleep_wake {

struct Inputs {
    bool touchInterruptLow;
    bool touchContact;
    bool buttonPressed;
};

enum class ReleaseResult : uint8_t { ready, inputActive, timedOut };

// A stuck GT911 interrupt must never trap sleep entry before the wake timer
// is armed. Keep this wait independent of M5Unified's unbounded release loop.
template <typename Clock, typename ReadInputs, typename Poll, typename Pause>
ReleaseResult waitForRelease(
    Clock now, ReadInputs readInputs, Poll poll, Pause pause,
    uint32_t timeoutMs = 250) {
    const uint32_t startedAt = now();
    for (;;) {
        const Inputs inputs = readInputs();
        if (inputs.touchContact || inputs.buttonPressed) {
            return ReleaseResult::inputActive;
        }
        if (!inputs.touchInterruptLow) {
            return ReleaseResult::ready;
        }
        if (static_cast<uint32_t>(now() - startedAt) >= timeoutMs) {
            return ReleaseResult::timedOut;
        }
        poll();
        pause();
    }
}

}  // namespace sleep_wake