#include "screensaver_battery.h"
#include <cassert>
#include <iostream>

int main() {
    using screensaver_battery::imagesOnly;
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
    std::cout << "PASS: battery policy disabled, 0-99%, 100%, unknown and transitions.\n";
}