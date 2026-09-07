#include "remote_schedule.h"
#include <cassert>
#include <iostream>

int main() {
    using remote_schedule::isDue;
    using remote_schedule::secondsUntilNext;

    constexpr uint8_t weekdays = 0b00111110;
    assert(isDue(weekdays, 7 * 60 + 30, 1, 7 * 60 + 30, 15));
    assert(isDue(weekdays, 7 * 60 + 30, 5, 7 * 60 + 45, 15));
    assert(!isDue(weekdays, 7 * 60 + 30, 0, 7 * 60 + 30, 15));
    assert(!isDue(weekdays, 7 * 60 + 30, 1, 7 * 60 + 46, 15));

    assert(secondsUntilNext(weekdays, 7 * 3600 + 30 * 60, 1, 7 * 3600) == 30 * 60);
    assert(secondsUntilNext(weekdays, 7 * 3600 + 30 * 60, 5, 8 * 3600) ==
        3 * 86400 - 30 * 60);
    assert(secondsUntilNext(0, 0, 0, 0) == remote_schedule::noUpcomingSchedule);

    std::cout << "PASS: weekday filtering, catch-up, and next schedule wake.\n";
}