#pragma once

#include "reference_pages.h"
#include "psram_json_allocator.h"
#include "bluetooth.h"
#include <memory>
#include <string>

namespace native_device {
class ProfileStore {
    PsramJsonAllocator allocator;
    std::unique_ptr<paper_board::NativeProfile, decltype(&heap_caps_free)> parsed{nullptr, &heap_caps_free};
    bool storageReady = false;
    bool liveValid = false;
    bool configured = false;
    uint32_t revision = 0;
    const char* error = "invalid_profile";
    struct Upload {
        std::string bytes;
        uint16_t owner = noConnection;
        uint32_t expected = 0, crc = 0, lastActivity = 0, nextAck = 0;
        bool finish = false;
    } upload;
public:
    JsonDocument json{&allocator};
    void (*beforeInstall)() = nullptr;
    void (*afterInstall)() = nullptr;
    bool begin();
    bool install(const std::string& payload, bool persist);
    bool consume(const BLEFrame& frame);
    void poll(uint32_t now);
    bool ready() const { return configured; }
    bool busy() const { return upload.owner != noConnection; }
    uint32_t generation() const { return revision; }
    const char* problem() const { return error; }
    paper_board::NativeProfile& bindings() { return *parsed; }
    size_t pageIndex() const;
    void changePage(int delta);
    std::string payload() const;
    bool authorized(const std::string& token) const;
};
}