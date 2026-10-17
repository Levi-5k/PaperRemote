#pragma once
#include <cstdint>

namespace paper_board {
class DescriptorLease {
public:
    static constexpr uint16_t noOwner = UINT16_MAX;
    static constexpr uint32_t leaseMilliseconds = 30000;
private:
    uint16_t owner_ = noOwner;
    uint32_t offset_ = 0, activity_ = 0;
    bool closing_ = false;
public:
    uint16_t owner() const { return owner_; }
    uint32_t offset() const { return offset_; }
    bool expired(uint32_t now) const {
        return owner_ != noOwner && uint32_t(now - activity_) >= leaseMilliseconds;
    }
    bool select(uint16_t handle, uint32_t offset, uint32_t now) {
        if (handle == noOwner || closing_ || expired(now)) return false;
        if (owner_ == noOwner) {
            if (offset != 0) return false;
            owner_ = handle;
        }
        if (owner_ != handle) return false;
        offset_ = offset;
        activity_ = now;
        return true;
    }
    bool read(uint16_t handle, uint32_t now) {
        if (owner_ != handle || handle == noOwner || closing_ || expired(now)) return false;
        activity_ = now;
        return true;
    }
    uint16_t expire(uint32_t now) {
        if (!expired(now)) return noOwner;
        // Do not hand off shared Read Blob storage until disconnect is confirmed.
        closing_ = true;
        return owner_;
    }
    void disconnected(uint16_t handle) {
        if (owner_ == handle) { owner_ = noOwner; offset_ = 0; closing_ = false; }
    }
    void eof(uint16_t handle) { disconnected(handle); }
};
}
