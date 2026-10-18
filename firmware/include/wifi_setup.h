#pragma once

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstring>

// Bluetooth Wi-Fi provisioning for native (non-M5Paper) boards: the phone asks the
// device to scan, the user picks a network and enters only its password.
namespace wifi_setup {

constexpr uint8_t scanRequest = 0x33;    // client -> device
constexpr uint8_t networkCount = 0x34;   // device -> client: [0x34, count]
constexpr uint8_t networkRead = 0x35;    // client: [0x35, index]; device: [0x35, index, rssi, secure, ssid...]
constexpr uint8_t statusRequest = 0x37;  // client -> device
constexpr uint8_t joinRequest = 0x39;    // client: [0x39, ssidLength, ssid..., password...]
constexpr uint8_t status = 0x3A;         // device: [0x3A, state, reasonLo, reasonHi, ip0..ip3, ssid...]
constexpr uint8_t failed = 0x7F;

constexpr size_t maxSSID = 32;
constexpr size_t maxPassword = 63;
constexpr size_t maxStatusBytes = 8 + maxSSID;
constexpr size_t maxNetworkBytes = 4 + maxSSID;

enum class State : uint8_t { notConfigured = 0, connecting = 1, connected = 2, failed = 3 };

// ESP-IDF station disconnect reasons that end an attempt, plus app-level failures.
namespace reason {
constexpr uint16_t none = 0;
constexpr uint16_t handshakeTimeout = 15;   // usually a wrong password
constexpr uint16_t noAccessPoint = 201;
constexpr uint16_t authenticationFailed = 202;
constexpr uint16_t associationFailed = 203;
constexpr uint16_t handshakeTimeout2 = 204;
constexpr uint16_t unauthorized = 0xFF01;    // connection is not paired with this device
constexpr uint16_t invalidRequest = 0xFF02;
constexpr uint16_t storageFailed = 0xFF03;
}  // namespace reason

struct Credentials {
    char ssid[maxSSID + 1] = {};
    char password[maxPassword + 1] = {};
};

// WPA2 passphrases are 8-63 characters; open networks have none.
inline bool parseJoin(const uint8_t* bytes, size_t length, Credentials& out) {
    if (length < 3 || bytes[0] != joinRequest) return false;
    const size_t ssidLength = bytes[1];
    if (ssidLength == 0 || ssidLength > maxSSID || length < 2 + ssidLength) return false;
    const size_t passwordLength = length - 2 - ssidLength;
    if (passwordLength > maxPassword || (passwordLength > 0 && passwordLength < 8)) return false;
    for (size_t i = 0; i < ssidLength + passwordLength; ++i)
        if (bytes[2 + i] == 0) return false;
    Credentials parsed;
    std::memcpy(parsed.ssid, bytes + 2, ssidLength);
    std::memcpy(parsed.password, bytes + 2 + ssidLength, passwordLength);
    out = parsed;
    return true;
}

inline size_t encodeNetwork(uint8_t* out, uint8_t index, int rssi, bool secure, const char* ssid) {
    const size_t ssidLength = ssid ? std::min(std::strlen(ssid), maxSSID) : 0;
    out[0] = networkRead;
    out[1] = index;
    out[2] = static_cast<uint8_t>(static_cast<int8_t>(rssi < -127 ? -127 : rssi > 0 ? 0 : rssi));
    out[3] = secure ? 1 : 0;
    if (ssidLength) std::memcpy(out + 4, ssid, ssidLength);
    return 4 + ssidLength;
}

inline size_t encodeStatus(uint8_t* out, State state, uint16_t why, const uint8_t ip[4], const char* ssid) {
    const size_t ssidLength = ssid ? std::min(std::strlen(ssid), maxSSID) : 0;
    out[0] = status;
    out[1] = static_cast<uint8_t>(state);
    out[2] = static_cast<uint8_t>(why);
    out[3] = static_cast<uint8_t>(why >> 8);
    for (size_t i = 0; i < 4; ++i) out[4 + i] = state == State::connected ? ip[i] : 0;
    if (ssidLength) std::memcpy(out + 8, ssid, ssidLength);
    return 8 + ssidLength;
}

inline bool definitiveFailure(uint16_t why) {
    return why == reason::handshakeTimeout || why == reason::noAccessPoint ||
        why == reason::authenticationFailed || why == reason::associationFailed ||
        why == reason::handshakeTimeout2;
}

// Tracks one join attempt. The radio keeps retrying in the background, so a failed
// attempt still becomes `connected` if the network appears later.
class JoinTracker {
public:
    static constexpr uint32_t timeoutMs = 20000;
    // Ignore early disconnects (the radio reports one when switching networks).
    static constexpr uint32_t settleMs = 1500;

    State state() const { return state_; }
    uint16_t why() const { return why_; }

    void begin(uint32_t now) {
        state_ = State::connecting;
        why_ = reason::none;
        startedAt_ = now;
    }
    void notConfigured() { state_ = State::notConfigured; why_ = reason::none; }
    void fail(uint16_t why) { state_ = State::failed; why_ = why; }

    // Returns true when the reported state changed.
    bool update(bool connected, uint16_t lastDisconnect, uint32_t now) {
        const State before = state_;
        const uint16_t beforeWhy = why_;
        if (state_ == State::notConfigured) return false;
        if (connected) {
            state_ = State::connected;
            why_ = reason::none;
        } else if (state_ == State::connected) {
            begin(now);
        } else if (state_ == State::connecting) {
            const uint32_t elapsed = now - startedAt_;
            if (elapsed >= settleMs && definitiveFailure(lastDisconnect)) fail(lastDisconnect);
            else if (elapsed >= timeoutMs) fail(lastDisconnect);
        }
        return state_ != before || why_ != beforeWhy;
    }

private:
    State state_ = State::notConfigured;
    uint16_t why_ = reason::none;
    uint32_t startedAt_ = 0;
};

}  // namespace wifi_setup
