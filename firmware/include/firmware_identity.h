#pragma once
#include <cstddef>
#include <cstdint>
#include <cstring>

namespace paper_board {
// A compatibility guard, not a signature or a substitute for authenticated updates.
constexpr char m5paperFirmwareIdentity[] = "PGIFBOARD:m5stack.m5paper@1.0;";
constexpr char referenceFirmwareIdentity[] = "PGIFBOARD:paperremote.esp32-screenless-reference@1;";
constexpr char superminiS3FirmwareIdentity[] = "PGIFBOARD:paperremote.supermini-s3-mt6701@1;";
class FirmwareIdentityScanner {
    size_t matched = 0;
    bool found = false;
public:
    void append(const uint8_t* data, size_t length) {
        for (size_t i = 0; i < length; ++i) {
            if (data[i] == static_cast<uint8_t>(m5paperFirmwareIdentity[matched])) ++matched;
            else matched = data[i] == m5paperFirmwareIdentity[0] ? 1 : 0;
            if (matched == sizeof(m5paperFirmwareIdentity) - 1) { found = true; matched = 0; }
        }
    }
    bool compatible() const { return found; }
};
}
