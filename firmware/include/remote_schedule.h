#pragma once

#include <stdint.h>

namespace remote_schedule {
constexpr uint8_t everyDayMask = 0x7F;
constexpr uint32_t noUpcomingSchedule = UINT32_MAX;

constexpr bool isDue(
    uint8_t weekdaysMask,
    uint16_t scheduledMinute,
    uint8_t currentWeekday,
    uint16_t currentMinute,
    uint16_t catchUpMinutes) {
    return currentWeekday < 7 &&
        (weekdaysMask & (1U << currentWeekday)) != 0 &&
        currentMinute >= scheduledMinute &&
        currentMinute - scheduledMinute <= catchUpMinutes;
}

inline uint32_t secondsUntilNext(
    uint8_t weekdaysMask,
    uint32_t scheduledSecond,
    uint8_t currentWeekday,
    uint32_t currentSecond) {
    if (weekdaysMask == 0 || currentWeekday >= 7 ||
        scheduledSecond >= 86400 || currentSecond >= 86400) {
        return noUpcomingSchedule;
    }
    for (uint8_t dayOffset = 0; dayOffset <= 7; ++dayOffset) {
        const uint8_t weekday = (currentWeekday + dayOffset) % 7;
        if ((weekdaysMask & (1U << weekday)) == 0) {
            continue;
        }
        const int32_t secondsUntil = static_cast<int32_t>(dayOffset) * 86400 +
            static_cast<int32_t>(scheduledSecond) - static_cast<int32_t>(currentSecond);
        if (secondsUntil > 0) {
            return static_cast<uint32_t>(secondsUntil);
        }
    }
    return noUpcomingSchedule;
}
}  // namespace remote_schedule