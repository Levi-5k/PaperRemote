#include "../include/wifi_setup.h"

#include <cassert>
#include <cstdio>
#include <vector>

using namespace wifi_setup;

static std::vector<uint8_t> join(const char* ssid, const char* password) {
    std::vector<uint8_t> packet{joinRequest, uint8_t(std::strlen(ssid))};
    packet.insert(packet.end(), ssid, ssid + std::strlen(ssid));
    packet.insert(packet.end(), password, password + std::strlen(password));
    return packet;
}

int main() {
    Credentials credentials;
    auto packet = join("Home 2.4", "correct horse");
    assert(parseJoin(packet.data(), packet.size(), credentials));
    assert(!std::strcmp(credentials.ssid, "Home 2.4") && !std::strcmp(credentials.password, "correct horse"));
    packet = join("Open Cafe", "");
    assert(parseJoin(packet.data(), packet.size(), credentials) && credentials.password[0] == 0);
    packet = join("Home", "short");
    assert(!parseJoin(packet.data(), packet.size(), credentials));      // WPA2 needs 8+
    packet = join("Home", std::string(64, 'x').c_str());
    assert(!parseJoin(packet.data(), packet.size(), credentials));      // > 63
    packet = join(std::string(33, 's').c_str(), "password1");
    assert(!parseJoin(packet.data(), packet.size(), credentials));      // SSID > 32
    const uint8_t truncated[] = {joinRequest, 10, 'a', 'b'};
    assert(!parseJoin(truncated, sizeof(truncated), credentials));
    const uint8_t embeddedNull[] = {joinRequest, 3, 'a', 0, 'b'};
    assert(!parseJoin(embeddedNull, sizeof(embeddedNull), credentials));
    assert(!std::strcmp(credentials.ssid, "Open Cafe"));                // failures leave output untouched

    uint8_t network[maxNetworkBytes];
    assert(encodeNetwork(network, 2, -200, true, "Lab") == 7);
    assert(network[0] == networkRead && network[1] == 2 && int8_t(network[2]) == -127 && network[3] == 1);
    assert(encodeNetwork(network, 0, -40, false, std::string(40, 'n').c_str()) == maxNetworkBytes);

    uint8_t frame[maxStatusBytes];
    const uint8_t ip[] = {192, 168, 50, 77};
    assert(encodeStatus(frame, State::connected, 0, ip, "Home") == 12);
    assert(frame[0] == status && frame[1] == 2 && frame[4] == 192 && frame[7] == 77 && frame[8] == 'H');
    encodeStatus(frame, State::failed, reason::unauthorized, ip, "Home");
    assert(frame[1] == 3 && frame[2] == 0x01 && frame[3] == 0xFF && frame[4] == 0);

    JoinTracker tracker;
    assert(!tracker.update(false, 0, 0) && tracker.state() == State::notConfigured);
    tracker.begin(1000);
    assert(!tracker.update(false, reason::authenticationFailed, 1500));  // still settling
    assert(tracker.update(false, reason::authenticationFailed, 3000) && tracker.state() == State::failed);
    assert(tracker.why() == reason::authenticationFailed);
    assert(tracker.update(true, 0, 9000) && tracker.state() == State::connected);  // network came back
    assert(tracker.update(false, 8, 10000) && tracker.state() == State::connecting); // lost: reconnecting
    assert(!tracker.update(false, 8, 25000));
    assert(tracker.update(false, 8, 30000) && tracker.state() == State::failed);     // timed out
    tracker.notConfigured();
    assert(!tracker.update(true, 0, 40000));
    std::puts("Wi-Fi setup tests passed");
}
