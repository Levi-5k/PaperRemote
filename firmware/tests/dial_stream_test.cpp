#include "../include/dial_stream.h"
#include <cassert>
#include <cstdio>
#include <cstring>

using namespace dial_stream;
using Send = Pacer::Send;

int main() {
    assert(intervalMicros(500) == 2000);
    assert(intervalMicros(75) == 13333);
    assert(intervalMicros(1000) == 2000 && intervalMicros(1) == intervalMicros(15));
    assert(validRate(15) && validRate(500) && !validRate(14.9) && !validRate(501) && !validRate(NAN));

    Pacer pacer;
    pacer.setRate(500);
    assert(pacer.poll(0) == Send::none);
    pacer.offer();
    assert(pacer.poll(100) == Send::fresh);  // First change goes out immediately.
    pacer.offer();
    assert(pacer.poll(1000) == Send::none);  // Held until the interval elapses...
    pacer.offer();                          // ...and only the newest value is kept.
    assert(pacer.poll(2100) == Send::fresh);
    assert(pacer.poll(2200) == Send::none);
    assert(pacer.poll(2100 + repeatDelayMicros) == Send::repeat);
    assert(pacer.poll(2100 + 2 * repeatDelayMicros) == Send::none && !pacer.active());

    Pacer slow;
    slow.setRate(15);  // 66 ms interval exceeds the repeat delay.
    slow.offer();
    assert(slow.poll(0) == Send::fresh);
    assert(slow.poll(repeatDelayMicros) == Send::none);
    assert(slow.poll(slow.interval_us()) == Send::repeat);
    // Wraparound of the 32-bit micros counter.
    Pacer wrap;
    wrap.offer();
    assert(wrap.poll(0xFFFFFF00u) == Send::fresh);
    wrap.offer();
    assert(wrap.poll(0x00004000u) == Send::fresh);

    char datagram[256];
    const size_t length = writeDatagram(datagram, sizeof(datagram), 7, 42, "tok",
        "{\"type\":\"macMedia\",\"text\":\"volume\",\"value\":128}");
    assert(length > 0 && std::strlen(datagram) == length);
    JsonDocument parsed;
    assert(!deserializeJson(parsed, datagram));
    assert(parsed["type"] == "paperGIF.dialStream" && parsed["boot"] == 7 && parsed["seq"] == 42);
    assert(parsed["token"] == "tok" && parsed["action"]["value"] == 128);
    assert(writeDatagram(datagram, 20, 7, 42, "tok", "{}") == 0);

    uint8_t live[7];
    assert(encodeLiveDial(live, 123.45, -720.5) == 7 && live[0] == liveDialOpcode);
    assert((live[1] | (live[2] << 8)) == 12345);
    const int32_t position = int32_t(uint32_t(live[3]) | uint32_t(live[4]) << 8 |
        uint32_t(live[5]) << 16 | uint32_t(live[6]) << 24);
    assert(position == -72050);
    puts("Dial stream pacing, datagram and live notification tests passed");
}
