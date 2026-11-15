#pragma once
#include "bluetooth.h"
#include "remote_button_texture.h"
#include <vector>

namespace native_device {
class MediaStore {
    std::string directory;
    std::string screenPath(size_t index) const;
    struct Entry { size_t slot; std::string name; std::string id; };
    std::vector<Entry> entries;
    size_t imageLimit = 4, uploadSlot = 0, cachedSlot = SIZE_MAX;
    uint8_t* screenPixels = nullptr;
    std::string uploadName;
    size_t freeSlot() const;
    size_t findID(const char* id) const;
    uint8_t* upload = nullptr;
    uint8_t* buttonPixels = nullptr;
    uint16_t owner = noConnection;
    uint32_t expected = 0, received = 0, crc = 0, activityAt = 0, nextAck = 0;
    uint32_t revision = 0;
    bool buttonUpload = false, storageReady = false;
    char imageID[37]{};
    void cancel();
    bool install();
public:
    explicit MediaStore(const std::string& directory = "/profiles") : directory(directory) {}
    ~MediaStore();
    MediaStore(const MediaStore&) = delete;
    MediaStore& operator=(const MediaStore&) = delete;
    void begin(bool ready, const std::string& path = "", size_t capacity = 4);
    bool consume(const BLEFrame& frame, bool profileBusy);
    bool library(const BLEFrame& frame, int activeIndex);
    int uploadHTTP(const uint8_t* bytes, size_t length, const char* id,
                   const char* title, uint32_t checksum, bool button, size_t& index);
    int removeHTTP(const char* id, bool button);
    void poll(uint32_t now);
    bool busy() const { return owner != noConnection; }
    uint32_t generation() const { return revision; }
    size_t count() const;
    const uint8_t* screen(size_t index);
    bool removeScreen(size_t index);
    const char* name(size_t index) const { return index < entries.size() ? entries[index].name.c_str() : ""; }
    size_t capacity() const { return imageLimit; }
    remote_button_texture::ImageView buttonImage(const char* id);
    void clearScreens();
};
}