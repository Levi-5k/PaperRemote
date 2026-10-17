#pragma once
#include <ArduinoJson.h>
#include <algorithm>
#include "board_driver.h"
#include "device_controls.h"

namespace paper_board {
constexpr size_t descriptorChunkBytes = 512;
constexpr size_t maxDescriptorBytes = 65536;
inline size_t descriptorSliceLength(size_t length, uint32_t offset) {
    return offset < length ? std::min(descriptorChunkBytes, length - offset) : 0;
}
inline void writeRect(JsonObject json, const Rect& r) {
    json["x"] = r.x; json["y"] = r.y;
    json["width"] = r.width; json["height"] = r.height;
}
inline void writeDeviceDescriptor(JsonDocument& json, const BoardInfo& board,
                                  const char* deviceID, const char* version,
                                  const device_controls::Control* controls = nullptr,
                                  size_t controlCount = 0) {
    json["schemaVersion"] = 1;
    json["protocolVersion"] = 1;
    json["deviceID"] = deviceID;
    json["name"] = board.name;
    json["manufacturer"] = board.manufacturer;
    json["boardID"] = board.id;
    json["hardwareRevision"] = board.revision;
    json["firmwareVersion"] = version;
    if (board.display) {
        auto display = json["display"].to<JsonObject>();
        display["width"] = board.display->width;
        display["height"] = board.display->height;
        display["touch"] = board.display->touch;
        display["pixelFormat"] = board.display->pixelFormat;
        display["rotation"] = board.display->rotation;
    } else json["display"] = nullptr;
    auto inputs = json["inputs"].to<JsonArray>();
    auto layout = json["layout"].to<JsonObject>();
    layout["width"] = board.bounds.width;
    layout["height"] = board.bounds.height;
    if (board.display) writeRect(layout["screen"].to<JsonObject>(), board.screen);
    auto positions = layout["inputs"].to<JsonArray>();
    for (size_t i = 0; i < board.inputCount; ++i) {
        const auto& input = board.inputs[i];
        auto item = inputs.add<JsonObject>();
        item["id"] = input.id; item["name"] = input.name; item["kind"] = input.kind;
        auto events = item["events"].to<JsonArray>();
        for (auto event : input.events) if (event) events.add(event);
        if (input.maximum > input.minimum) {
            item["minimum"] = input.minimum; item["maximum"] = input.maximum;
        }
        auto position = positions.add<JsonObject>();
        position["id"] = input.id;
        writeRect(position, input.bounds);
    }
    auto capabilities = json["capabilities"].to<JsonObject>();
    auto versions = capabilities["profileVersions"].to<JsonArray>();
    versions.add(6);
    if (board.profile7) versions.add(7);
    capabilities["media"] = board.display != nullptr;
    capabilities["firmwareUpdate"] = board.firmwareUpdate;
    capabilities["maxProfileBytes"] = board.maxProfileBytes;
    capabilities["maxControls"] = board.maxControls;
    capabilities["maxPages"] = board.maxPages;
    auto transports = capabilities["transports"].to<JsonArray>();
    transports.add("http");
    transports.add("ble");
    if (controls != nullptr && controlCount > 0) {
        device_controls::writeControls(json["controls"].to<JsonArray>(), controls, controlCount);
    }
}
}
