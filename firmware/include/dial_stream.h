#pragma once

#include <ArduinoJson.h>
#include <algorithm>
#include <cmath>
#include <cstdint>

// Low-latency dial streaming: change-only values sent at a capped rate, latest value wins.
namespace dial_stream {
constexpr double defaultRate = 75, minimumRate = 15, maximumRate = 500;
// Bluetooth live-dial notification: opcode, shaft angle (centidegrees, u16 LE),
// position (centidegrees, i32 LE).
constexpr uint8_t liveDialOpcode = 0x62;
constexpr uint32_t repeatDelayMicros = 60000;

inline bool validRate(double rate) { return std::isfinite(rate) && rate >= minimumRate && rate <= maximumRate; }
inline uint32_t intervalMicros(double rate) {
    return uint32_t(1e6 / std::max(minimumRate, std::min(maximumRate, std::isfinite(rate) ? rate : defaultRate)));
}

// Holds the newest value until the rate interval allows sending it, then repeats the final
// value once after motion stops so a lost datagram cannot leave the target on a stale value.
class Pacer {
    uint32_t interval = intervalMicros(defaultRate), sentAt = 0;
    bool pending = false, repeatDue = false, sentOnce = false;
public:
    enum class Send : uint8_t { none, fresh, repeat };
    void setRate(double rate) { interval = intervalMicros(rate); }
    uint32_t interval_us() const { return interval; }
    void offer() { pending = true; }
    void reset() { pending = repeatDue = sentOnce = false; }
    bool active() const { return pending || repeatDue; }
    Send poll(uint32_t now) {
        if (pending && (!sentOnce || now - sentAt >= interval)) {
            pending = false;
            repeatDue = sentOnce = true;
            sentAt = now;
            return Send::fresh;
        }
        if (!pending && repeatDue && now - sentAt >= std::max(repeatDelayMicros, interval)) {
            repeatDue = false;
            sentAt = now;
            return Send::repeat;
        }
        return Send::none;
    }
};

// Datagram sent to a companion's action port over UDP. `boot` changes on every restart so a
// receiver can reset its ordering; `seq` increases per datagram and stale ones are dropped.
inline size_t writeDatagram(char* out, size_t capacity, uint32_t boot, uint32_t seq,
                            const char* token, const char* actionJSON) {
    JsonDocument json;
    json["type"] = "paperGIF.dialStream";
    json["version"] = 1;
    json["boot"] = boot;
    json["seq"] = seq;
    json["token"] = token;
    json["action"] = serialized(actionJSON);
    const size_t length = measureJson(json);
    if (length >= capacity) return 0;
    return serializeJson(json, out, capacity);
}

inline size_t encodeLiveDial(uint8_t* out, double shaftAngle, double position) {
    const uint16_t angle = uint16_t(std::lround(std::max(0.0, std::min(359.99, shaftAngle)) * 100));
    const double scaled = std::max(-2147483647.0, std::min(2147483647.0, std::round(position * 100)));
    const int32_t centi = int32_t(scaled);
    out[0] = liveDialOpcode;
    out[1] = uint8_t(angle);
    out[2] = uint8_t(angle >> 8);
    for (int i = 0; i < 4; ++i) out[3 + i] = uint8_t(uint32_t(centi) >> (8 * i));
    return 7;
}
}  // namespace dial_stream
