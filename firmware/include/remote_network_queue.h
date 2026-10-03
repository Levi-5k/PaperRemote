#pragma once

#include <stddef.h>
#include <stdint.h>
#include <string.h>

namespace remote_network {

enum class Lane : uint8_t { interactive, climate, background, count };

inline Lane laneFor(const char* actionType, bool background) {
    return background ? Lane::background
        : strncmp(actionType, "netHome", 7) == 0 ? Lane::climate : Lane::interactive;
}

inline uint32_t responseTimeoutMs(Lane lane, bool textRequest) {
    return textRequest ? 15000 : lane == Lane::climate ? 35000 : 5000;
}

// Single consumer per lane. All access, including hasWork(), must be protected
// by the caller's mutex. A popped request remains work until finish() is called.
template <typename Request, size_t Capacity>
class WorkQueue {
public:
    bool enqueue(const Request& request) {
        // Coalesce only consecutive updates to the SAME slider. Never overwrite
        // a different control, or move a value across an intervening button.
        if (count_ > 0) {
            Request& tail = requests_[(head_ + count_ - 1) % Capacity];
            if (request.slider && tail.slider &&
                request.profileRevision == tail.profileRevision &&
                strcmp(request.controlId, tail.controlId) == 0 &&
                strcmp(request.url, tail.url) == 0) {
                tail = request;
                return true;
            }
        }
        if (count_ == Capacity) {
            return false;
        }
        requests_[(head_ + count_) % Capacity] = request;
        ++count_;
        return true;
    }

    bool take(Request& request) {
        if (active_ || count_ == 0) {
            return false;
        }
        request = requests_[head_];
        head_ = (head_ + 1) % Capacity;
        --count_;
        active_ = true;
        return true;
    }

    void finish() { active_ = false; }
    bool hasWork() const { return active_ || count_ > 0; }

private:
    static_assert(Capacity > 0, "A network queue needs storage");
    Request requests_[Capacity] = {};
    size_t head_ = 0;
    size_t count_ = 0;
    bool active_ = false;
};

} // namespace remote_network