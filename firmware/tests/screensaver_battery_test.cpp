#include "screensaver_battery.h"
#include <cassert>
#include <iostream>

int main() {
    using screensaver_battery::imagesOnly;
    using screensaver_battery::nextImageIndex;
    using screensaver_battery::noImageIndex;
    for (int percent = -1; percent <= 100; ++percent) {
        assert(!imagesOnly(false, percent));
        assert(imagesOnly(true, percent) == (percent != 100));
    }
    // The threshold is exact, independent of a charging connection, and must
    // work in both directions as the sampled battery crosses full charge.
    const int levels[] = {99, 100, 99, -1, 100, 0};
    const bool expected[] = {true, false, true, true, false, true};
    for (unsigned i = 0; i < sizeof(levels) / sizeof(levels[0]); ++i) {
        assert(imagesOnly(true, levels[i]) == expected[i]);
    }
    assert(imagesOnly(true, 101));

    const uint16_t mixedFrames[] = {12, 1, 8, 1};
    assert(nextImageIndex(mixedFrames, 4, 0) == 1);
    assert(nextImageIndex(mixedFrames, 4, 2) == 3);
    assert(nextImageIndex(mixedFrames, 4, 4) == 1);

    const uint16_t animatedFrames[] = {12, 8, 20};
    assert(nextImageIndex(animatedFrames, 3, 0) == 0);
    assert(nextImageIndex(animatedFrames, 3, 1) == 1);
    assert(nextImageIndex(animatedFrames, 3, 2) == 2);
    assert(nextImageIndex(animatedFrames, 3, 3) == 0);
    assert(nextImageIndex(animatedFrames, 0, 0) == noImageIndex);

    std::cout << "PASS: battery policy and still-first fallback rotation.\n";
}