#include "../include/media_timeline.h"

#include <cassert>
#include <iostream>

namespace {
struct Action {
    const char* type;
    const char* text;
    int value;
};
struct Control {
    bool slider;
    uint8_t kind;
    Action action;
};

media_timeline::State timeline(uint32_t elapsed, uint32_t duration, bool playing = true) {
    media_timeline::State state;
    state.available = true;
    state.playing = playing;
    state.stale = false;
    state.elapsedMilliseconds = elapsed;
    state.durationMilliseconds = duration;
    state.sampledAt = 1000;
    return state;
}
}

int main() {
    using namespace media_timeline;
    State desktop = timeline(12345, 240000);
    State phone = timeline(65432, 300000);
    const Control transport[] = {
        {true, 1, {"macMedia", "volume", 128}},
        {false, 0, {"macMedia", "playPause", 0}},
    };
    // Main/Windows pages have transport controls without a seek slider.
    auto position = positionForControls(transport, 2, desktop, phone, -1, 1000);
    assert(position.available && position.elapsedSeconds == 12 && position.durationSeconds == 240);
    assert(positionForControls(transport, 2, desktop, phone, -1, 1700).elapsedSeconds == 13);
    desktop.playing = false;
    position = positionForControls(transport, 2, desktop, phone, -1, 5000);
    assert(position.available && position.elapsedSeconds == 12);
    desktop.playing = true;

    const Control phoneControls[] = {
        {true, 1, {"iPhoneMedia", "seek", 200}},
        {false, 0, {"iPhoneMedia", "playPause", 0}},
    };
    position = positionForControls(phoneControls, 2, desktop, phone, -1, 1000);
    assert(position.elapsedSeconds == 65 && position.durationSeconds == 300);
    desktop.available = false;
    assert(positionForControls(phoneControls, 2, desktop, phone, -1, 1000) == position);
    phone.available = false;
    desktop.available = true;
    assert(!positionForControls(phoneControls, 2, desktop, phone, -1, 1000).available);
    phone.available = true;

    // A seek drag wins over the other source's slider/playback controls.
    Control mixed[] = {
        {false, 0, {"macMedia", "playPause", 0}},
        {true, 1, {"iPhoneMedia", "seek", 128}},
        {true, 1, {"macMedia", "seek", 255}},
    };
    position = positionForControls(mixed, 3, desktop, phone, -1, 1000);
    assert(position.elapsedSeconds == 65 && position.durationSeconds == 300);
    position = positionForControls(mixed, 3, desktop, phone, 2, 1000);
    assert(position.elapsedSeconds == 240 && position.durationSeconds == 240);
    position = positionForControls(mixed, 3, desktop, phone, 1, 1000);
    assert(position.elapsedSeconds == 150 && position.durationSeconds == 300);
    mixed[1].action.value = -1;
    assert(positionForControls(mixed, 3, desktop, phone, 1, 1000).elapsedSeconds == 0);
    mixed[1].action.value = 999;
    assert(positionForControls(mixed, 3, desktop, phone, 1, 1000).elapsedSeconds == 300);

    const Control other[] = {{true, 1, {"wledBrightness", "seek", 128}}};
    assert(!positionForControls(other, 1, desktop, phone, -1, 1000).available);
    assert(!positionForControls(other, 0, desktop, phone, -1, 1000).available);
    desktop.durationMilliseconds = 0;
    assert(!positionForControls(transport, 2, desktop, phone, -1, 1000).available);

    // Two-hour media must tick even when its 8-bit seek position doesn't change.
    desktop = timeline(60000, 7200000);
    const Control seek[] = {{true, 1, {"macMedia", "seek", 2}}};
    const auto first = positionForControls(seek, 1, desktop, phone, -1, 1000);
    assert(positionForControls(seek, 1, desktop, phone, -1, 1999) == first);
    const auto second = positionForControls(seek, 1, desktop, phone, -1, 2000);
    assert(second != first && second.elapsedSeconds == 61);
    assert(elapsedAt(desktop, 1000) * 255ULL / desktop.durationMilliseconds ==
        elapsedAt(desktop, 2000) * 255ULL / desktop.durationMilliseconds);
    desktop.stale = true;
    assert(elapsedAt(desktop, 8000) == 60000);
    assert(positionForControls(seek, 1, desktop, phone, -1, 8000) == first);

    desktop = timeline(239500, 240000);
    assert(elapsedAt(desktop, 5000) == 240000);
    desktop = timeline(UINT32_MAX - 500, UINT32_MAX);
    assert(elapsedAt(desktop, 2000) == UINT32_MAX);
    desktop = timeline(1000, 240000);
    desktop.sampledAt = UINT32_MAX - 499;
    assert(elapsedAt(desktop, 500) == 2000);  // millis() wraparound.

    std::cout << "PASS: media position on transport/seek pages, desktop/iPhone sources, "
                 "pause, drag priority, second-level invalidation, stale/end and overflow.\n";
}