#pragma once

#include <Arduino.h>
#include <ArduinoJson.h>
#include <NimBLEDevice.h>
#include "descriptor_json.h"
#include "descriptor_lease.h"
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>

namespace paper_board {
constexpr char descriptorUuid[] = "7A230004-7D2A-4C7B-9C42-504749460001";
inline String descriptor(const BoardInfo& board, const char* version,
                         const device_controls::Control* controls = nullptr,
                         size_t controlCount = 0) {
    JsonDocument json;
    char id[24];
    snprintf(id, sizeof(id), "papergif-%012llx", ESP.getEfuseMac());
    writeDeviceDescriptor(json, board, id, version, controls, controlCount);
    String result;
    serializeJson(json, result);
    return result;
}

class DescriptorCallbacks final : public NimBLECharacteristicCallbacks {
    DescriptorLease lease;
    SemaphoreHandle_t mutex = nullptr;
    NimBLECharacteristic* characteristic = nullptr;
    uint32_t cachedOffset = 0;
    size_t cachedLength = 0;
    const String& json;
    void restoreCache() {
        characteristic->setValue(reinterpret_cast<const uint8_t*>(json.c_str()) +
            (cachedLength ? cachedOffset : 0), cachedLength);
    }
    static void disconnect(uint16_t handle) {
        if (auto* server = NimBLEDevice::getServer()) server->disconnect(handle);
    }
public:
    explicit DescriptorCallbacks(const String& value) : json(value) {}
    void attach(NimBLECharacteristic* value) {
        if (!mutex) mutex = xSemaphoreCreateMutex();
        if (!mutex) abort();
        xSemaphoreTake(mutex, portMAX_DELAY);
        characteristic = value;
        lease = DescriptorLease{};
        cachedOffset = 0;
        cachedLength = 0;
        restoreCache();
        xSemaphoreGive(mutex);
    }
    void poll(uint32_t now) {
        if (!mutex) return;
        xSemaphoreTake(mutex, portMAX_DELAY);
        const uint16_t expired = lease.expire(now);
        xSemaphoreGive(mutex);
        if (expired != DescriptorLease::noOwner) disconnect(expired);
    }
    void disconnected(uint16_t handle) {
        if (!mutex) return;
        xSemaphoreTake(mutex, portMAX_DELAY);
        lease.disconnected(handle);
        xSemaphoreGive(mutex);
    }
    void onWrite(NimBLECharacteristic* characteristic, NimBLEConnInfo& info) override {
        const auto value = characteristic->getValue();
        const uint16_t handle = info.getConnHandle();
        xSemaphoreTake(mutex, portMAX_DELAY);
        bool accepted = false;
        if (value.size() == 4) {
            const uint32_t offset = uint32_t(value[0]) | uint32_t(value[1]) << 8 |
                uint32_t(value[2]) << 16 | uint32_t(value[3]) << 24;
            accepted = lease.select(handle, offset, millis());
        }
        // NimBLE replaces the characteristic value before this callback. Restore it even
        // for a rejected write so another connection cannot corrupt an owner's Read Blob.
        restoreCache();
        xSemaphoreGive(mutex);
        if (!accepted) {
            Serial.println("Descriptor request rejected: busy, unclaimed, expired, or invalid offset write");
            disconnect(handle);
        }
    }
    void onRead(NimBLECharacteristic* characteristic, NimBLEConnInfo& info) override {
        const uint16_t handle = info.getConnHandle();
        xSemaphoreTake(mutex, portMAX_DELAY);
        const bool accepted = lease.read(handle, millis());
        if (accepted) {
            cachedOffset = lease.offset();
            cachedLength = descriptorSliceLength(json.length(), cachedOffset);
            restoreCache();
            // A short nonempty slice can still have pending ATT Read Blob requests.
            // Only an explicit empty EOF read can release its backing storage safely.
            if (!cachedLength) lease.eof(handle);
        }
        xSemaphoreGive(mutex);
        if (!accepted) disconnect(handle);
    }
};
inline void addDescriptorCharacteristic(NimBLEService* service, DescriptorCallbacks& callbacks) {
    auto* characteristic = service->createCharacteristic(descriptorUuid,
        NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::WRITE, descriptorChunkBytes);
    callbacks.attach(characteristic);
    characteristic->setCallbacks(&callbacks);
}
} // namespace paper_board
