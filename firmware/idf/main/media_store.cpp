#include "media_store.h"
#include "screen_image.h"
#include "esp_heap_caps.h"
#include "esp_timer.h"
#include <algorithm>
#include <cstdio>
#include <string>
#include <unistd.h>

namespace native_device {
namespace {
constexpr uint16_t width = 368, height = 448;
constexpr size_t screenBytes = screen_image::headerBytes + size_t(width) * height * 2;
constexpr size_t maxButtonBytes = 329738;
uint32_t read32(const uint8_t* bytes) {
    return uint32_t(bytes[0]) | uint32_t(bytes[1]) << 8 | uint32_t(bytes[2]) << 16 | uint32_t(bytes[3]) << 24;
}
uint8_t* readImage(const std::string& path, size_t maximum, size_t& length) {
    FILE* file = std::fopen(path.c_str(), "rb");
    if (!file) return nullptr;
    std::fseek(file, 0, SEEK_END);
    const long size = std::ftell(file);
    std::rewind(file);
    auto* bytes = size > 0 && size_t(size) <= maximum
        ? static_cast<uint8_t*>(heap_caps_malloc(size, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT)) : nullptr;
    if (bytes && std::fread(bytes, 1, size, file) != size_t(size)) { heap_caps_free(bytes); bytes = nullptr; }
    std::fclose(file);
    length = bytes ? size_t(size) : 0;
    return bytes;
}
}
std::string MediaStore::screenPath(size_t index) const { return directory + "/screen-" + std::to_string(index) + ".pimg"; }
MediaStore::~MediaStore() {
    cancel();
    heap_caps_free(screenPixels);
    heap_caps_free(buttonPixels);
}
void MediaStore::begin(bool ready, const std::string& path, size_t capacity) {
    cancel();
    heap_caps_free(screenPixels);
    screenPixels = nullptr;
    cachedSlot = SIZE_MAX;
    entries.clear();
    if (!path.empty()) directory = path;
    imageLimit = std::clamp(capacity, size_t(1), size_t(128));
    storageReady = ready;
    if (!ready) return;
    std::remove((directory + "/image.new").c_str());
    for (size_t index = 0; index < imageLimit; ++index) {
        FILE* file = std::fopen(screenPath(index).c_str(), "rb");
        if (!file) continue;
        uint8_t header[10]{};
        const bool headerRead = std::fread(header, 1, sizeof(header), file) == sizeof(header);
        std::fseek(file, 0, SEEK_END);
        const long length = std::ftell(file);
        std::fclose(file);
        if (!headerRead || length != long(screenBytes) ||
            !screen_image::valid(header, screenBytes, width, height)) continue;
        char title[49]{};
        file = std::fopen((screenPath(index) + ".txt").c_str(), "rb");
        if (file) { std::fread(title, 1, sizeof(title) - 1, file); std::fclose(file); }
        char identifier[37]{}, normalized[37]{};
        file = std::fopen((screenPath(index) + ".id").c_str(), "rb");
        if (file) { std::fread(identifier, 1, sizeof(identifier) - 1, file); std::fclose(file); }
        remote_button_texture::normalizeImageId(identifier, normalized);
        entries.push_back({index, title[0] ? std::string(title) : "Image " + std::to_string(index + 1), normalized});
    }
    ++revision;
}
size_t MediaStore::freeSlot() const {
    for (size_t slot = 0; slot < imageLimit; ++slot) {
        FILE* file = std::fopen(screenPath(slot).c_str(), "rb");
        if (!file) return slot;
        std::fclose(file);
    }
    return imageLimit;
}
void MediaStore::cancel() {
    heap_caps_free(upload);
    upload = nullptr;
    owner = noConnection;
    received = expected = 0;
}
size_t MediaStore::findID(const char* id) const {
    if (id && id[0]) {
        for (size_t index = 0; index < entries.size(); ++index)
            if (entries[index].id == id) return index;
    }
    return SIZE_MAX;
}
bool MediaStore::install() {
    if (received != expected || screen_image::checksum(upload, received) != crc) return false;
    uint16_t imageWidth = 0, imageHeight = 0;
    if (buttonUpload ? !remote_button_texture::parseImageHeader(upload, received, imageWidth, imageHeight)
                     : !screen_image::valid(upload, received, width, height)) return false;
    const std::string path = buttonUpload ? directory + "/button-" + imageID + ".pbgi" : screenPath(uploadSlot);
    if (buttonUpload || findID(imageID) != SIZE_MAX) {
        size_t length = 0;
        auto* existing = readImage(path, buttonUpload ? maxButtonBytes : screenBytes, length);
        if (existing) {
            const bool identical = length == received && !std::memcmp(existing, upload, length);
            heap_caps_free(existing);
            return identical;
        }
    }
    const std::string temporary = directory + "/image.new";
    FILE* file = std::fopen(temporary.c_str(), "wb");
    bool written = file && std::fwrite(upload, 1, received, file) == received;
    if (file) {
        written = std::fflush(file) == 0 && written;
        written = fsync(fileno(file)) == 0 && written;
        written = std::fclose(file) == 0 && written;
    }
    const std::string identifierPath = path + ".id";
    if (written && !buttonUpload && imageID[0]) {
        FILE* identifier = std::fopen(identifierPath.c_str(), "wb");
        written = identifier && std::fwrite(imageID, 1, 36, identifier) == 36;
        if (identifier) {
            written = std::fflush(identifier) == 0 && written;
            written = fsync(fileno(identifier)) == 0 && written;
            written = std::fclose(identifier) == 0 && written;
        }
    }
    if (!written || std::rename(temporary.c_str(), path.c_str())) {
        std::remove(temporary.c_str());
        if (!buttonUpload) std::remove(identifierPath.c_str());
        return false;
    }
    if (!buttonUpload) {
        FILE* title = std::fopen((path + ".txt").c_str(), "wb");
        if (title) { std::fwrite(uploadName.data(), 1, uploadName.size(), title); std::fclose(title); }
        entries.push_back({uploadSlot, uploadName, imageID});
        heap_caps_free(screenPixels);
        screenPixels = upload;
        cachedSlot = uploadSlot;
        upload = nullptr;
    }
    ++revision;
    return true;
}
int MediaStore::uploadHTTP(const uint8_t* bytes, size_t length, const char* id,
                          const char* title, uint32_t checksum, bool button, size_t& index) {
    if (!storageReady) return 503;
    if (busy()) return 409;
    uint16_t imageWidth = 0, imageHeight = 0;
    if (!remote_button_texture::normalizeImageId(id, imageID) ||
        (button ? !remote_button_texture::parseImageHeader(bytes, length, imageWidth, imageHeight)
                : !screen_image::valid(bytes, length, width, height)) ||
        length > (button ? maxButtonBytes : screenBytes) || screen_image::checksum(bytes, length) != checksum) return 400;
    index = button ? SIZE_MAX : findID(imageID);
    bool duplicate = !button && index != SIZE_MAX;
    if (button) {
        FILE* existing = std::fopen((directory + "/button-" + imageID + ".pbgi").c_str(), "rb");
        duplicate = existing != nullptr;
        if (existing) std::fclose(existing);
    }
    uploadSlot = !button && duplicate ? entries[index].slot : freeSlot();
    if (!button && uploadSlot >= imageLimit) return 507;
    upload = static_cast<uint8_t*>(heap_caps_malloc(length, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
    if (!upload) return 503;
    std::memcpy(upload, bytes, length);
    received = expected = length;
    crc = checksum;
    buttonUpload = button;
    uploadName.clear();
    for (const char* character = title; character && *character && uploadName.size() < 48; ++character)
        if (*character >= 32 && *character <= 126) uploadName += *character;
    if (uploadName.empty()) uploadName = "Image " + std::to_string(uploadSlot + 1);
    const bool installed = install();
    cancel();
    if (!installed) return duplicate ? 409 : 500;
    if (!button) index = findID(imageID);
    return duplicate ? 200 : 201;
}
int MediaStore::removeHTTP(const char* id, bool button) {
    if (!storageReady) return 503;
    if (busy()) return 409;
    char normalized[37]{};
    if (!remote_button_texture::normalizeImageId(id, normalized)) return 400;
    if (button) {
        if (std::remove((directory + "/button-" + normalized + ".pbgi").c_str())) return 404;
        ++revision;
        return 200;
    }
    const size_t index = findID(normalized);
    if (index == SIZE_MAX) return 404;
    return removeScreen(index) ? 200 : 500;
}
bool MediaStore::consume(const BLEFrame& frame, bool profileBusy) {
    auto reply = [&](uint8_t code) { notify(frame.connection, &code, 1); };
    if (frame.kind == FrameKind::disconnected) {
        if (owner == frame.connection) cancel();
        return false;
    }
    const bool control = frame.kind == FrameKind::control && frame.length;
    if (control && (frame.bytes[0] == 0x10 || frame.bytes[0] == 0x16 || frame.bytes[0] == 0x46)) {
        const bool button = frame.bytes[0] == 0x46;
        const bool identified = button || frame.bytes[0] == 0x16;
        if (!storageReady || busy() || profileBusy || frame.length < (identified ? 45 : 9) || (button && frame.length != 45)) {
            reply(0x7f); return true;
        }
        const uint32_t size = read32(frame.bytes + 1);
        char identifier[37]{};
        imageID[0] = 0;
        if (identified) std::memcpy(identifier, frame.bytes + 9, 36);
        if (size < 10 || size > (button ? maxButtonBytes : screenBytes) ||
            (identified && !remote_button_texture::normalizeImageId(identifier, imageID))) { reply(0x7f); return true; }
        if (!button) {
            const size_t existing = findID(imageID);
            uploadSlot = existing == SIZE_MAX ? freeSlot() : entries[existing].slot;
            if (uploadSlot >= imageLimit) { reply(0x7f); return true; }
            uploadName.clear();
            for (size_t index = identified ? 45 : 9; index < frame.length && uploadName.size() < 48; ++index) {
                if (frame.bytes[index] >= 32 && frame.bytes[index] <= 126) uploadName += char(frame.bytes[index]);
            }
            if (uploadName.empty()) uploadName = "Image " + std::to_string(uploadSlot + 1);
        }
        upload = static_cast<uint8_t*>(heap_caps_malloc(size, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
        if (!upload) { reply(0x7f); return true; }
        owner = frame.connection;
        expected = size;
        received = 0;
        crc = read32(frame.bytes + 5);
        buttonUpload = button;
        nextAck = std::min(uint32_t(16384), expected);
        reply(button ? 0x41 : 0x11);
    } else if (control && (frame.bytes[0] == 0x12 || frame.bytes[0] == 0x47)) {
        if (owner != frame.connection || frame.length != 1 || frame.bytes[0] != (buttonUpload ? 0x47 : 0x12)) {
            reply(0x7f); return true;
        }
        reply(install() ? (buttonUpload ? 0x48 : 0x13) : 0x7f);
        cancel();
    } else if (frame.kind == FrameKind::data && busy()) {
        if (owner != frame.connection) { reply(0x7f); return true; }
        if (frame.length > expected - received) { reply(0x7f); cancel(); return true; }
        std::memcpy(upload + received, frame.bytes, frame.length);
        received += frame.length;
        if (received >= nextAck) {
            const uint8_t response[] = {uint8_t(buttonUpload ? 0x45 : 0x15), uint8_t(received),
                uint8_t(received >> 8), uint8_t(received >> 16), uint8_t(received >> 24)};
            notify(owner, response, sizeof(response));
            nextAck = std::min(expected, nextAck + 16384);
        }
        if (received == expected) reply(buttonUpload ? 0x44 : 0x14);
    } else return false;
    activityAt = uint32_t(esp_timer_get_time() / 1000);
    return true;
}
void MediaStore::poll(uint32_t now) {
    if (busy() && now - activityAt >= 30000) {
        const uint8_t error = 0x7f;
        notify(owner, &error, 1);
        cancel();
    }
}
size_t MediaStore::count() const {
    return entries.size();
}
const uint8_t* MediaStore::screen(size_t index) {
    if (entries.empty()) return nullptr;
    const size_t slot = entries[index % entries.size()].slot;
    if (slot != cachedSlot) {
        size_t length = 0;
        auto* bytes = readImage(screenPath(slot), screenBytes, length);
        if (!screen_image::valid(bytes, length, width, height)) { heap_caps_free(bytes); return nullptr; }
        heap_caps_free(screenPixels);
        screenPixels = bytes;
        cachedSlot = slot;
    }
    return screenPixels ? screenPixels + screen_image::headerBytes : nullptr;
}
remote_button_texture::ImageView MediaStore::buttonImage(const char* id) {
    char normalized[37]{};
    if (!remote_button_texture::normalizeImageId(id, normalized)) return {};
    heap_caps_free(buttonPixels);
    size_t length = 0;
    buttonPixels = readImage(directory + "/button-" + normalized + ".pbgi", maxButtonBytes, length);
    uint16_t imageWidth = 0, imageHeight = 0;
    if (!buttonPixels || !remote_button_texture::parseImageHeader(buttonPixels, length, imageWidth, imageHeight)) return {};
    return {buttonPixels + 10, imageWidth, imageHeight, buttonPixels[4] == 2};
}
bool MediaStore::removeScreen(size_t index) {
    if (busy() || index >= entries.size()) return false;
    const size_t slot = entries[index].slot;
    if (std::remove(screenPath(slot).c_str())) return false;
    std::remove((screenPath(slot) + ".txt").c_str());
    std::remove((screenPath(slot) + ".id").c_str());
    if (cachedSlot == slot) {
        heap_caps_free(screenPixels);
        screenPixels = nullptr;
        cachedSlot = SIZE_MAX;
    }
    entries.erase(entries.begin() + index);
    ++revision;
    return true;
}
void MediaStore::clearScreens() {
    for (size_t index = entries.size(); index > 0; --index) removeScreen(index - 1);
}
bool MediaStore::library(const BLEFrame& frame, int activeIndex) {
    if (frame.kind != FrameKind::control || !frame.length) return false;
    const uint8_t command = frame.bytes[0];
    if (command != 0x20 && command != 0x22 && command != 0x23) return false;
    if (busy() || !storageReady || frame.length != (command == 0x20 ? 1 : 2)) {
        const uint8_t error = 0x7f;
        notify(frame.connection, &error, 1);
    } else if (command == 0x20) {
        const uint8_t response[] = {0x21, uint8_t(count())};
        notify(frame.connection, response, sizeof(response));
    } else if (command == 0x23) {
        const uint8_t response[] = {0x24, frame.bytes[1], uint8_t(removeScreen(frame.bytes[1]))};
        notify(frame.connection, response, sizeof(response));
    } else if (frame.bytes[1] < entries.size()) {
        const auto& entry = entries[frame.bytes[1]];
        uint8_t response[53] = {0x22, frame.bytes[1], uint8_t(frame.bytes[1] == activeIndex), 1, 0};
        const size_t length = std::min(size_t(48), entry.name.size());
        std::memcpy(response + 5, entry.name.data(), length);
        notify(frame.connection, response, length + 5);
    } else {
        const uint8_t error = 0x7f;
        notify(frame.connection, &error, 1);
    }
    return true;
}
}