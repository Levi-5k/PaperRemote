#pragma once
#include <cstdint>

namespace paper_board {
constexpr uint32_t uploadIdleMilliseconds = 30000;
inline bool uploadIdleExpired(uint16_t owner, uint32_t lastActivity, uint32_t now) {
    return owner != UINT16_MAX && uint32_t(now - lastActivity) >= uploadIdleMilliseconds;
}
template <typename Upload, typename Notify>
bool expireIdleUpload(Upload& upload, uint32_t now, Notify notify) {
    if (!uploadIdleExpired(upload.owner, upload.lastActivity, now)) return false;
    notify(upload.owner);
    upload = Upload{};
    return true;
}
template <typename Storage, typename Warning>
bool mountReferenceStorage(Storage& storage, bool allowFormat, Warning warning) {
    if (storage.begin(false)) return true;
    warning("LittleFS mount failed; existing storage has not been formatted.");
    if (!allowFormat) return false;
    warning("DESTRUCTIVE OPT-IN: formatting LittleFS after mount failure; existing profiles will be erased.");
    return storage.format() && storage.begin(false);
}
}
