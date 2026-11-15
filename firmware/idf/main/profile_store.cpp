#include "profile_store.h"
#include "reference_lifecycle.h"
#include "esp_littlefs.h"
#include "esp_log.h"
#include "esp_timer.h"
#include <cstdio>
#include <unistd.h>

namespace native_device {
namespace {
constexpr const char* livePath = "/profiles/remote.json";
constexpr const char* backupPath = "/profiles/remote.bak";
constexpr const char* temporaryPath = "/profiles/remote.new";
uint32_t read32(const uint8_t* data) {
    return uint32_t(data[0]) | uint32_t(data[1]) << 8 | uint32_t(data[2]) << 16 | uint32_t(data[3]) << 24;
}
uint32_t checksum(const std::string& bytes) {
    uint32_t result = UINT32_MAX;
    for (uint8_t value : bytes) {
        result ^= value;
        for (int bit = 0; bit < 8; ++bit) result = (result >> 1) ^ (0xedb88320U & (0U - (result & 1)));
    }
    return ~result;
}
void reply(uint16_t handle, uint8_t code) { notify(handle, &code, 1); }
}
bool ProfileStore::begin() {
    void* memory = heap_caps_malloc(sizeof(paper_board::NativeProfile), MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (!memory) return false;
    parsed.reset(new (memory) paper_board::NativeProfile);
    esp_vfs_littlefs_conf_t config{};
    config.base_path = "/profiles";
    config.partition_label = "spiffs";
    config.format_if_mount_failed = false;
    storageReady = esp_vfs_littlefs_register(&config) == ESP_OK;
    if (!storageReady) {
        ESP_LOGE("profile", "LittleFS unavailable; existing flash was not formatted");
        return false;
    }
    for (const auto* path : {livePath, backupPath}) {
        FILE* file = std::fopen(path, "rb");
        if (!file) continue;
        std::fseek(file, 0, SEEK_END);
        const long size = std::ftell(file);
        std::rewind(file);
        std::string bytes;
        if (size > 0 && size <= long(paper_board::waveshareAmoled18V2().maxProfileBytes)) {
            bytes.resize(size);
            if (std::fread(bytes.data(), 1, bytes.size(), file) != bytes.size()) bytes.clear();
        }
        std::fclose(file);
        if (!bytes.empty() && install(bytes, false)) { liveValid = path == livePath; break; }
    }
    return true;
}
bool ProfileStore::install(const std::string& payload, bool persist) {
    error = "invalid_profile";
    const auto& board = paper_board::waveshareAmoled18V2();
    if (payload.empty() || payload.size() > board.maxProfileBytes) return false;
    JsonDocument candidate(&allocator);
    const auto jsonError = deserializeJson(candidate, payload, DeserializationOption::NestingLimit(24));
    if (jsonError) { error = jsonError.c_str(); return false; }
    void* memory = heap_caps_malloc(sizeof(paper_board::NativeProfile), MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (!memory) { error = "profile_memory_unavailable"; return false; }
    decltype(parsed) next(new (memory) paper_board::NativeProfile, &heap_caps_free);
    if (!paper_board::parseNativeProfile(candidate, *next, board, &error) ||
        !paper_board::validTouchPages(candidate)) return false;
    bool hasToken = std::strlen(candidate["macToken"] | "") > 0;
    for (JsonObjectConst computer : candidate["computers"].as<JsonArrayConst>())
        hasToken = hasToken || std::strlen(computer["token"] | "") > 0;
    if (!hasToken) { error = "missing_profile_token"; return false; }
    if (persist) {
        if (!storageReady) { error = "storage_not_ready"; return false; }
        FILE* file = std::fopen(temporaryPath, "wb");
        bool written = file && std::fwrite(payload.data(), 1, payload.size(), file) == payload.size();
        if (file) {
            written = std::fflush(file) == 0 && written;
            written = fsync(fileno(file)) == 0 && written;
            written = std::fclose(file) == 0 && written;
        }
        if (!written) { std::remove(temporaryPath); error = "profile_write_failed"; return false; }
        if (liveValid) {
            std::remove(backupPath);
            if (std::rename(livePath, backupPath)) { error = "profile_backup_failed"; return false; }
        }
        if (std::rename(temporaryPath, livePath)) {
            if (liveValid) std::rename(backupPath, livePath);
            error = "profile_install_failed"; return false;
        }
        liveValid = true;
    }
    if (beforeInstall) beforeInstall();
    if (parsed) for (JsonObjectConst page : candidate["pages"].as<JsonArrayConst>()) {
        if (!std::strcmp(page["id"] | "", parsed->activePageID))
            std::strcpy(next->activePageID, parsed->activePageID);
    }
    json = std::move(candidate);
    parsed = std::move(next);
    configured = true;
    ++revision;
    ESP_LOGI("profile", "Profile accepted: %u pages", unsigned(json["pages"].size()));
    if (afterInstall) afterInstall();
    return true;
}
bool ProfileStore::consume(const BLEFrame& frame) {
    if (frame.kind == FrameKind::disconnected) {
        if (upload.owner == frame.connection) upload = Upload{};
        return false;
    }
    if (frame.kind == FrameKind::control && frame.length == 9 && frame.bytes[0] == 0x40) {
        const uint32_t size = read32(frame.bytes + 1);
        if (busy() || !size || size > paper_board::waveshareAmoled18V2().maxProfileBytes) {
            reply(frame.connection, 0x7f); return true;
        }
        upload = Upload{};
        upload.owner = frame.connection;
        upload.expected = size;
        upload.crc = read32(frame.bytes + 5);
        upload.bytes.reserve(size);
        upload.nextAck = std::min(uint32_t(16384), size);
        reply(frame.connection, 0x41);
    } else if (frame.kind == FrameKind::control && frame.length == 1 && frame.bytes[0] == 0x42) {
        if (upload.owner != frame.connection) { reply(frame.connection, 0x7f); return true; }
        upload.finish = true;
    } else if (frame.kind == FrameKind::data) {
        if (upload.owner != frame.connection || upload.bytes.size() + frame.length > upload.expected) {
            reply(frame.connection, 0x7f); return true;
        }
        upload.bytes.append(reinterpret_cast<const char*>(frame.bytes), frame.length);
        if (upload.bytes.size() >= upload.nextAck) {
            const uint32_t size = upload.bytes.size();
            const uint8_t response[] = {0x45, uint8_t(size), uint8_t(size >> 8), uint8_t(size >> 16), uint8_t(size >> 24)};
            notify(frame.connection, response, sizeof(response));
            upload.nextAck = std::min(upload.expected, upload.nextAck + 16384);
        }
        if (upload.bytes.size() == upload.expected) reply(frame.connection, 0x44);
    } else return false;
    upload.lastActivity = uint32_t(esp_timer_get_time() / 1000);
    if (upload.finish && upload.bytes.size() == upload.expected) {
        const bool valid = checksum(upload.bytes) == upload.crc && install(upload.bytes, true);
        if (!valid) ESP_LOGW("profile", "Profile rejected: %s", error);
        reply(upload.owner, valid ? 0x43 : 0x7f);
        upload = Upload{};
    }
    return true;
}
void ProfileStore::poll(uint32_t now) {
    paper_board::expireIdleUpload(upload, now, [](uint16_t handle) { reply(handle, 0x7f); });
}
size_t ProfileStore::pageIndex() const {
    size_t index = 0;
    for (JsonObjectConst page : json["pages"].as<JsonArrayConst>()) {
        if (!std::strcmp(page["id"] | "", parsed->activePageID)) return index;
        ++index;
    }
    return 0;
}
void ProfileStore::changePage(int delta) {
    const int count = json["pages"].size();
    if (!count) return;
    const auto index = ((int(pageIndex()) + delta) % count + count) % count;
    std::strcpy(parsed->activePageID, json["pages"][index]["id"] | "");
}
std::string ProfileStore::payload() const { std::string result; serializeJson(json, result); return result; }
bool ProfileStore::authorized(const std::string& token) const {
    if (!configured || token.empty()) return false;
    if (token == (json["macToken"] | "")) return true;
    for (JsonObjectConst computer : json["computers"].as<JsonArrayConst>())
        if (token == (computer["token"] | "")) return true;
    return false;
}
}