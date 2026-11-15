#pragma once

#include <array>
#include <cstdint>
#include <cstddef>
#include <string>

namespace native_device {
constexpr uint16_t noConnection = UINT16_MAX;
enum class FrameKind { control, data, disconnected };
struct BLEFrame {
    FrameKind kind = FrameKind::control;
    uint16_t connection = noConnection;
    uint16_t length = 0;
    uint8_t bytes[512]{};
};
bool beginBluetooth(const std::string& descriptor);
bool readBluetooth(BLEFrame& frame);
bool notify(uint16_t connection, const uint8_t* bytes, size_t length);
size_t notificationCapacity(uint16_t connection);
std::array<uint16_t, 2> connections();
void pollBluetooth();
}