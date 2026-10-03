#include "../include/sleep_wake.h"
#include <cassert>
#include <iostream>

struct Fixture {
    uint32_t now = 0;
    unsigned polls = 0;
    sleep_wake::Inputs inputs{false, false, false};
    unsigned releaseAfter = 0;
    unsigned pressAfter = 0;

    sleep_wake::ReleaseResult run() {
        return sleep_wake::waitForRelease(
            [&]() { return now; },
            [&]() { return inputs; },
            [&]() {
                ++polls;
                if (releaseAfter != 0 && polls == releaseAfter) inputs.touchInterruptLow = false;
                if (pressAfter != 0 && polls == pressAfter) inputs.buttonPressed = true;
            },
            [&]() { now += 5; });
    }
};

int main() {
    using sleep_wake::ReleaseResult;
    Fixture idle;
    assert(idle.run() == ReleaseResult::ready);
    assert(idle.polls == 0);

    Fixture stuck;
    stuck.inputs.touchInterruptLow = true;
    assert(stuck.run() == ReleaseResult::timedOut);
    assert(stuck.now == 250 && stuck.polls == 50);

    Fixture cleared;
    cleared.inputs.touchInterruptLow = true;
    cleared.releaseAfter = 3;
    assert(cleared.run() == ReleaseResult::ready);
    assert(cleared.polls == 3 && cleared.now == 15);

    Fixture heldTouch;
    heldTouch.inputs = {true, true, false};
    assert(heldTouch.run() == ReleaseResult::inputActive);
    assert(heldTouch.polls == 0);

    Fixture heldButton;
    heldButton.inputs.buttonPressed = true;
    assert(heldButton.run() == ReleaseResult::inputActive);
    assert(heldButton.polls == 0);

    Fixture buttonDuringWait;
    buttonDuringWait.inputs.touchInterruptLow = true;
    buttonDuringWait.pressAfter = 2;
    assert(buttonDuringWait.run() == ReleaseResult::inputActive);
    assert(buttonDuringWait.now == 10);

    Fixture rollover;
    rollover.now = UINT32_MAX - 100;
    rollover.inputs.touchInterruptLow = true;
    const uint32_t startedAt = rollover.now;
    assert(rollover.run() == ReleaseResult::timedOut);
    assert(static_cast<uint32_t>(rollover.now - startedAt) == 250);

    // A later attempt can succeed after the hardware releases; timeout is not
    // a latched failure and must not disable future touch wake.
    stuck.inputs.touchInterruptLow = false;
    assert(stuck.run() == ReleaseResult::ready);
    std::cout << "PASS: bounded sleep entry, input cancellation, retry and rollover.\n";
}