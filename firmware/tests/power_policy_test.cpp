#include "power_policy.h"
#include <cassert>
#include <iostream>

int main() {
    using namespace power_policy;

    uint32_t backoff = homeWifiRetryMinimumMs;
    const uint32_t expected[] = {60000, 120000, 240000, 300000, 300000};
    for (uint32_t value : expected) {
        backoff = nextHomeWifiBackoffMs(backoff);
        assert(backoff == value);
    }
    assert(homeWifiRetryIntervalMs(false, false, 240000) == 240000);
    assert(homeWifiRetryIntervalMs(false, true, 240000) == 30000);
    assert(homeWifiRetryIntervalMs(true, true, 30000) == 300000);

    assert(wifiTxPowerQuarterDbm(0, false) == 78);
    assert(wifiTxPowerQuarterDbm(-75, false) == 78);
    assert(wifiTxPowerQuarterDbm(-61, false) == 78);
    assert(wifiTxPowerQuarterDbm(-60, false) == 60);
    assert(wifiTxPowerQuarterDbm(-51, false) == 60);
    assert(wifiTxPowerQuarterDbm(-50, false) == 44);
    assert(wifiTxPowerQuarterDbm(-30, false) == 44);
    assert(wifiTxPowerQuarterDbm(-30, true) == 78);

    assert(ssidHash("Home") == ssidHash("Home"));
    assert(ssidHash("Home") != ssidHash("home"));
    assert(ssidHash("") == 2166136261UL);

    std::cout << "PASS: Wi-Fi retry backoff, transmit power and SSID cache key.\n";
}
