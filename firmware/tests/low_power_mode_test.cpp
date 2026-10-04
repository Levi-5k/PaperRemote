#include "low_power_mode.h"
#include <cassert>
#include <iostream>

int main() {
    using namespace low_power_mode;
    for (int percent = 0; percent <= 100; ++percent) {
        assert(next(false, percent) == (percent < 30));
        assert(next(true, percent) == (percent < 35));
    }
    assert(!next(false, -1));
    assert(next(true, -1));

    // A discharge, sag/recovery near the threshold, then charging past 35%.
    const int levels[] = {31, 30, 29, 31, 34, 33, 35, 32, 29};
    const bool expected[] = {false, false, true, true, true, true, false, false, true};
    bool active = false;
    for (unsigned i = 0; i < sizeof(levels) / sizeof(levels[0]); ++i) {
        active = next(active, levels[i]);
        assert(active == expected[i]);
    }

    assert(idleDelayMs(false, 900000) == 900000);
    assert(idleDelayMs(true, 900000) == 60000);
    assert(idleDelayMs(true, 10000) == 10000);

    assert(refreshIntervalMs(false, 5000) == 5000);
    assert(refreshIntervalMs(true, 5000) == 60000);
    assert(refreshIntervalMs(true, 0) == 0);
    assert(refreshIntervalMs(true, 120000) == 120000);

    std::cout << "PASS: low power mode hysteresis and limits.\n";
}
