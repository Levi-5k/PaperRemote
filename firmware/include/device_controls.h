#pragma once

// Platform-independent device controls and BLE relay helpers
// (protocol/device-protocol.md: "Device controls" and "Bluetooth fallback").
// Kept C++11 compatible for the ESP32 Arduino toolchain.

#include <ArduinoJson.h>
#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>

namespace device_controls {

enum class Kind : uint8_t { toggle, range, select, action };

struct Option {
    const char* value;
    const char* name;
};

struct Control {
    const char* id;
    const char* name;
    Kind kind;
    const char* group;
    double minimum;
    double maximum;
    double step;
    const char* unit;
    const Option* options;
    uint8_t optionCount;
    bool readOnly;
    bool confirm;
};

enum class Status : uint8_t { ok = 0, unknownControl = 1, invalidValue = 2, readOnly = 3, busy = 4 };

constexpr uint8_t snapshotRequest = 0x50;
constexpr uint8_t snapshotFragment = 0x51;
constexpr uint8_t setRequest = 0x52;
constexpr uint8_t setResult = 0x53;
constexpr uint8_t relayRegister = 0x70;
constexpr uint8_t relayRegistered = 0x71;
constexpr uint8_t relayAction = 0x72;
constexpr uint8_t relayResult = 0x73;
constexpr uint8_t finalFragment = 0x01;
constexpr size_t maxSetRequestBytes = 240;
constexpr size_t maxControls = 64;
constexpr size_t safePacketBytes = 180;

inline const char* errorName(Status status) {
    switch (status) {
    case Status::unknownControl: return "unknown_control";
    case Status::invalidValue: return "invalid_value";
    case Status::readOnly: return "read_only";
    case Status::busy: return "busy";
    default: return "";
    }
}

inline int httpStatus(Status status) {
    switch (status) {
    case Status::ok: return 200;
    case Status::unknownControl: return 404;
    case Status::busy: return 409;
    default: return 400;
    }
}

inline const char* kindName(Kind kind) {
    switch (kind) {
    case Kind::toggle: return "toggle";
    case Kind::range: return "range";
    case Kind::select: return "select";
    default: return "action";
    }
}

struct Value {
    Kind kind = Kind::action;
    bool boolean = false;
    double number = 0;
    const char* text = nullptr;  // Points at the matched Option::value.

    static Value ofBool(bool value) { Value v; v.kind = Kind::toggle; v.boolean = value; return v; }
    static Value ofNumber(double value) { Value v; v.kind = Kind::range; v.number = value; return v; }
    static Value ofText(const char* value) { Value v; v.kind = Kind::select; v.text = value; return v; }
};

inline bool validId(const char* id) {
    if (id == nullptr) return false;
    size_t length = 0;
    for (; id[length] != '\0'; ++length) {
        const char c = id[length];
        const bool ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
            (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-';
        if (!ok || length >= 64) return false;
    }
    return length > 0;
}

inline const Control* find(const Control* controls, size_t count, const char* id) {
    if (id == nullptr) return nullptr;
    for (size_t index = 0; index < count; ++index) {
        if (std::strcmp(controls[index].id, id) == 0) return &controls[index];
    }
    return nullptr;
}

inline double snap(const Control& control, double value) {
    double snapped = value;
    if (control.step > 0) {
        snapped = control.minimum +
            std::round((value - control.minimum) / control.step) * control.step;
    }
    // Remove binary noise such as 21.300000000000001 before the limit checks, so
    // a value on the maximum (359.9 -> 359.90000000000003) is not stepped down.
    auto clean = [](double value) { return std::round(value * 1e6) / 1e6; };
    snapped = clean(snapped);
    if (snapped > control.maximum) snapped = clean(snapped - control.step);
    if (snapped < control.minimum) snapped = control.minimum;
    return snapped;
}

// Validates a set request value. `present` is false when the request omitted
// `value`. On success `out` holds the normalized value (snapped number, matched
// option pointer, or an action marker).
inline Status validate(const Control& control, JsonVariantConst value, bool present, Value& out) {
    if (control.readOnly) return Status::readOnly;
    switch (control.kind) {
    case Kind::action:
        if (present) return Status::invalidValue;
        out = Value();
        return Status::ok;
    case Kind::toggle:
        if (!present || !value.is<bool>()) return Status::invalidValue;
        out = Value::ofBool(value.as<bool>());
        return Status::ok;
    case Kind::range: {
        if (!present || value.is<bool>() || !(value.is<double>() || value.is<long long>()))
            return Status::invalidValue;
        const double number = value.as<double>();
        // ArduinoJson may hold parsed numbers as 32-bit floats (0.01 -> 0.0099999998),
        // so accept float rounding at a limit; snap() then clamps to the exact bound.
        auto slack = [](double bound) { return std::max(1.0, std::fabs(bound)) * 1e-6; };
        if (!std::isfinite(number) || number < control.minimum - slack(control.minimum) ||
            number > control.maximum + slack(control.maximum))
            return Status::invalidValue;
        out = Value::ofNumber(snap(control, number));
        return Status::ok;
    }
    case Kind::select:
        if (!present || !value.is<const char*>()) return Status::invalidValue;
        for (uint8_t index = 0; index < control.optionCount; ++index) {
            if (std::strcmp(control.options[index].value, value.as<const char*>()) == 0) {
                out = Value::ofText(control.options[index].value);
                return Status::ok;
            }
        }
        return Status::invalidValue;
    }
    return Status::invalidValue;
}

// Parses `{"id":…,"value":…}`. `control` is set when the ID is known.
inline Status parseSetRequest(const char* json, size_t length, const Control* controls,
                              size_t count, const Control*& control, Value& value) {
    control = nullptr;
    if (json == nullptr || length == 0 || length > maxSetRequestBytes) return Status::invalidValue;
    JsonDocument document;
    if (deserializeJson(document, json, length) || !document.is<JsonObjectConst>())
        return Status::invalidValue;
    JsonObjectConst request = document.as<JsonObjectConst>();
    for (JsonPairConst pair : request) {
        const char* key = pair.key().c_str();
        if (std::strcmp(key, "id") != 0 && std::strcmp(key, "value") != 0)
            return Status::invalidValue;
    }
    JsonVariantConst id = request["id"];
    if (!id.is<const char*>() || !validId(id.as<const char*>())) return Status::invalidValue;
    control = find(controls, count, id.as<const char*>());
    if (control == nullptr) return Status::unknownControl;
    JsonVariantConst raw = request["value"];
    const bool present = !raw.isUnbound() && !raw.isNull();
    if (!raw.isUnbound() && raw.isNull()) return Status::invalidValue;
    return validate(*control, raw, present, value);
}

inline void writeValue(JsonObject values, const char* id, const Value& value) {
    switch (value.kind) {
    case Kind::toggle: values[id] = value.boolean; break;
    case Kind::range:
        if (value.number == std::floor(value.number) && std::fabs(value.number) < 2147483647.0)
            values[id] = static_cast<long>(value.number);
        else
            values[id] = value.number;
        break;
    case Kind::select: if (value.text) values[id] = value.text; break;
    default: break;
    }
}

// `read(control, value)` returns false to omit a value (e.g. an unavailable sensor).
template <typename Reader>
void writeSnapshot(JsonObject values, const Control* controls, size_t count, Reader read) {
    for (size_t index = 0; index < count; ++index) {
        const Control& control = controls[index];
        if (control.kind == Kind::action) continue;
        Value value;
        value.kind = control.kind;
        if (read(control, value)) {
            value.kind = control.kind;
            writeValue(values, control.id, value);
        }
    }
}

inline void writeError(JsonDocument& json, const char* error) {
    json["ok"] = false;
    json["error"] = error;
}

inline void writeControls(JsonArray array, const Control* controls, size_t count) {
    for (size_t index = 0; index < count && index < maxControls; ++index) {
        const Control& control = controls[index];
        JsonObject item = array.add<JsonObject>();
        item["id"] = control.id;
        item["name"] = control.name;
        item["kind"] = kindName(control.kind);
        if (control.group) item["group"] = control.group;
        if (control.kind == Kind::range) {
            Value minimum = Value::ofNumber(control.minimum);
            Value maximum = Value::ofNumber(control.maximum);
            Value step = Value::ofNumber(control.step);
            writeValue(item, "minimum", minimum);
            writeValue(item, "maximum", maximum);
            writeValue(item, "step", step);
            if (control.unit) item["unit"] = control.unit;
        }
        if (control.kind == Kind::select) {
            JsonArray options = item["options"].to<JsonArray>();
            for (uint8_t option = 0; option < control.optionCount; ++option) {
                JsonObject entry = options.add<JsonObject>();
                entry["value"] = control.options[option].value;
                entry["name"] = control.options[option].name;
            }
        }
        if (control.kind != Kind::action && control.readOnly) item["readOnly"] = true;
        if (control.kind == Kind::action && control.confirm) item["confirm"] = true;
    }
}

// Largest notification packet (opcode included) for a negotiated ATT MTU.
inline size_t packetLimit(uint16_t mtu) {
    size_t limit = mtu > 23 ? static_cast<size_t>(mtu) - 3 : 20;
    return limit < safePacketBytes ? limit : safePacketBytes;
}

// Sends `data` as packets of [header…][flags][fragment] where flags bit 0 marks
// the final fragment. Empty data still sends one final packet. `send(bytes,
// length)` returns false to abort. Returns the number of packets sent or -1.
template <typename Sender>
int sendFragments(const uint8_t* header, size_t headerLength, const char* data, size_t length,
                  size_t maxPacket, Sender send) {
    uint8_t packet[safePacketBytes];
    if (maxPacket > sizeof(packet)) maxPacket = sizeof(packet);
    if (headerLength + 2 > maxPacket) return -1;
    const size_t chunk = maxPacket - headerLength - 1;
    size_t offset = 0;
    int packets = 0;
    do {
        const size_t remaining = length - offset;
        const size_t take = remaining < chunk ? remaining : chunk;
        std::memcpy(packet, header, headerLength);
        packet[headerLength] = offset + take >= length ? finalFragment : 0;
        if (take) std::memcpy(packet + headerLength + 1, data + offset, take);
        if (!send(packet, headerLength + 1 + take)) return -1;
        offset += take;
        ++packets;
    } while (offset < length);
    return packets;
}

// Builds {"computerId":…,"body":{…}} where body is the exact /action JSON.
inline size_t writeRelayAction(char* out, size_t capacity, const char* computerId,
                               const char* body) {
    JsonDocument json;
    json["computerId"] = computerId ? computerId : "";
    json["body"] = serialized(body);
    const size_t needed = measureJson(json);
    if (needed + 1 > capacity) return 0;
    return serializeJson(json, out, capacity);
}

// Matches a relay pairing token. Returns a computer index, remote_computer
// legacy (-1) for the single legacy computer, or -2 when unknown.
template <typename TokenAt>
int tokenComputerIndex(const char* token, size_t tokenLength, const char* legacyToken,
                       size_t computerCount, TokenAt tokenAt) {
    if (token == nullptr || tokenLength == 0) return -2;
    const auto same = [&](const char* candidate) {
        return candidate != nullptr && candidate[0] != '\0' &&
            std::strlen(candidate) == tokenLength &&
            std::memcmp(candidate, token, tokenLength) == 0;
    };
    for (size_t index = 0; index < computerCount; ++index) {
        if (same(tokenAt(index))) return static_cast<int>(index);
    }
    if (same(legacyToken)) return computerCount > 0 ? 0 : -1;
    return -2;
}

enum class RelayRole : uint8_t { computer = 0, forwarder = 1 };

class RelayRegistry {
public:
    static constexpr size_t capacity = 8;
    static constexpr uint16_t none = 0xFFFF;
    struct Entry {
        uint16_t handle;
        int16_t computer;
        RelayRole role;
    };

    bool add(uint16_t handle, int computer, RelayRole role) {
        for (size_t index = 0; index < count_; ++index) {
            if (entries_[index].handle == handle && entries_[index].computer == computer) {
                entries_[index].role = role;
                return true;
            }
        }
        if (count_ >= capacity) return false;
        entries_[count_].handle = handle;
        entries_[count_].computer = static_cast<int16_t>(computer);
        entries_[count_].role = role;
        ++count_;
        return true;
    }
    void removeHandle(uint16_t handle) {
        size_t write = 0;
        for (size_t read = 0; read < count_; ++read) {
            if (entries_[read].handle != handle) entries_[write++] = entries_[read];
        }
        count_ = write;
    }
    // Returns the relay handle for a computer, preferring a direct computer relay.
    uint16_t find(int computer, bool directOnly = false) const {
        uint16_t forwarder = none;
        for (size_t index = 0; index < count_; ++index) {
            if (entries_[index].computer != computer) continue;
            if (entries_[index].role == RelayRole::computer) return entries_[index].handle;
            if (forwarder == none) forwarder = entries_[index].handle;
        }
        return directOnly ? none : forwarder;
    }
    bool isRelay(uint16_t handle) const {
        for (size_t index = 0; index < count_; ++index) {
            if (entries_[index].handle == handle) return true;
        }
        return false;
    }
    size_t size() const { return count_; }
    void clear() { count_ = 0; }

private:
    Entry entries_[capacity] = {};
    size_t count_ = 0;
};

// Connection handles that asked for snapshots and get unsolicited updates.
class HandleSet {
public:
    static constexpr size_t capacity = 4;
    bool add(uint16_t handle) {
        if (contains(handle)) return true;
        if (count_ >= capacity) return false;
        handles_[count_++] = handle;
        return true;
    }
    void remove(uint16_t handle) {
        size_t write = 0;
        for (size_t read = 0; read < count_; ++read) {
            if (handles_[read] != handle) handles_[write++] = handles_[read];
        }
        count_ = write;
    }
    bool contains(uint16_t handle) const {
        for (size_t index = 0; index < count_; ++index) {
            if (handles_[index] == handle) return true;
        }
        return false;
    }
    size_t size() const { return count_; }
    uint16_t at(size_t index) const { return handles_[index]; }
    void clear() { count_ = 0; }

private:
    uint16_t handles_[capacity] = {};
    size_t count_ = 0;
};

// Outstanding relay sequences so a 0x73 can be matched to a computer.
class RelaySequences {
public:
    static constexpr size_t capacity = 8;
    uint8_t next(uint16_t handle) {
        const uint8_t sequence = ++last_;
        Entry& entry = entries_[cursor_];
        entry.handle = handle;
        entry.sequence = sequence;
        entry.used = true;
        cursor_ = (cursor_ + 1) % capacity;
        return sequence;
    }
    // Returns true and forgets the sequence when it was outstanding for this handle.
    bool complete(uint16_t handle, uint8_t sequence) {
        for (size_t index = 0; index < capacity; ++index) {
            Entry& entry = entries_[index];
            if (entry.used && entry.handle == handle && entry.sequence == sequence) {
                entry.used = false;
                return true;
            }
        }
        return false;
    }
    void removeHandle(uint16_t handle) {
        for (size_t index = 0; index < capacity; ++index) {
            if (entries_[index].handle == handle) entries_[index].used = false;
        }
    }

private:
    struct Entry { uint16_t handle; uint8_t sequence; bool used; };
    Entry entries_[capacity] = {};
    size_t cursor_ = 0;
    uint8_t last_ = 0;
};

}  // namespace device_controls
