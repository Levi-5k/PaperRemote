#include "../include/descriptor_json.h"
#include "../include/device_controls.h"
#include "../include/m5paper_controls.h"
#include "../include/reference_controls.h"
#include <cassert>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

using namespace device_controls;
using paper_board::esp32Reference;
using paper_board::m5paper;
using paper_board::writeDeviceDescriptor;

static const Control* m5(const char* id) {
    const Control* control = find(m5paper_controls::controls, m5paper_controls::count, id);
    assert(control != nullptr);
    return control;
}

static Status parse(const std::string& json, const Control*& control, Value& value) {
    return parseSetRequest(json.data(), json.size(), m5paper_controls::controls,
        m5paper_controls::count, control, value);
}

static void validationTests() {
    const Control* control = nullptr;
    Value value;
    assert(parse(R"({"id":"slideshow","value":true})", control, value) == Status::ok);
    assert(control == m5("slideshow") && value.kind == Kind::toggle && value.boolean);
    assert(parse(R"({"id":"slideshow","value":1})", control, value) == Status::invalidValue);
    assert(parse(R"({"id":"slideshow"})", control, value) == Status::invalidValue);
    assert(parse(R"({"id":"slideshow","value":null})", control, value) == Status::invalidValue);

    // Ranges snap to the step anchored at the minimum and reject values outside the bounds.
    assert(parse(R"({"id":"sleepDelay","value":44})", control, value) == Status::ok);
    assert(value.number == 40);
    assert(parse(R"({"id":"sleepDelay","value":45.5})", control, value) == Status::ok);
    assert(value.number == 50);
    assert(parse(R"({"id":"sleepDelay","value":3600})", control, value) == Status::ok);
    assert(value.number == 3600);
    assert(parse(R"({"id":"sleepDelay","value":9})", control, value) == Status::invalidValue);
    assert(parse(R"({"id":"sleepDelay","value":3601})", control, value) == Status::invalidValue);
    assert(parse(R"({"id":"sleepDelay","value":true})", control, value) == Status::invalidValue);
    assert(parse(R"({"id":"sleepDelay","value":"60"})", control, value) == Status::invalidValue);
    const Control odd{"odd", "Odd", Kind::range, nullptr, 1, 10, 4, nullptr, nullptr, 0, false, false};
    assert(snap(odd, 9.9) == 9);  // 1, 5, 9: never snap above the maximum.
    assert(snap(odd, 2.9) == 1);
    const Control fine{"fine", "Fine", Kind::range, nullptr, 0, 1, 0.1, nullptr, nullptr, 0, false, false};
    assert(snap(fine, 0.33) == 0.3);

    assert(parse(R"({"id":"screenSaver","value":"geometricSnake"})", control, value) == Status::ok);
    assert(std::strcmp(value.text, "geometricSnake") == 0);
    assert(parse(R"({"id":"screenSaver","value":"bogus"})", control, value) == Status::invalidValue);
    assert(parse(R"({"id":"screenSaver","value":3})", control, value) == Status::invalidValue);

    assert(parse(R"({"id":"battery","value":50})", control, value) == Status::readOnly);
    assert(parse(R"({"id":"lowPowerMode","value":true})", control, value) == Status::readOnly);
    assert(parse(R"({"id":"restart"})", control, value) == Status::ok);
    assert(control == m5("restart") && control->confirm);
    assert(parse(R"({"id":"restart","value":true})", control, value) == Status::invalidValue);

    assert(parse(R"({"id":"missing","value":true})", control, value) == Status::unknownControl);
    assert(control == nullptr);
    assert(parse(R"({"id":"bad id!","value":true})", control, value) == Status::invalidValue);
    assert(parse(R"({"id":"slideshow","value":true,"extra":1})", control, value) == Status::invalidValue);
    assert(parse(R"([1,2])", control, value) == Status::invalidValue);
    assert(parse("{", control, value) == Status::invalidValue);
    assert(parse("", control, value) == Status::invalidValue);
    assert(parse(std::string(maxSetRequestBytes + 1, ' '), control, value) == Status::invalidValue);

    assert(httpStatus(Status::ok) == 200);
    assert(httpStatus(Status::unknownControl) == 404);
    assert(httpStatus(Status::invalidValue) == 400);
    assert(httpStatus(Status::readOnly) == 400);
    assert(httpStatus(Status::busy) == 409);
    assert(std::strcmp(errorName(Status::readOnly), "read_only") == 0);
    assert(std::strcmp(errorName(Status::unknownControl), "unknown_control") == 0);
}

static void tableTests() {
    for (const auto& table : {std::make_pair(m5paper_controls::controls, size_t(m5paper_controls::count)),
                              std::make_pair(reference_controls::controls, size_t(reference_controls::count))}) {
        assert(table.second <= maxControls);
        for (size_t index = 0; index < table.second; ++index) {
            const Control& control = table.first[index];
            assert(validId(control.id));
            assert(find(table.first, table.second, control.id) == &control);
            if (control.kind == Kind::range) {
                assert(control.minimum < control.maximum);
                assert(control.step > 0 && control.step <= control.maximum - control.minimum);
            }
            if (control.kind == Kind::select) assert(control.optionCount > 0 && control.options);
        }
    }
}

static std::string snapshotJson(bool ok) {
    JsonDocument json;
    if (ok) json["ok"] = true;
    writeSnapshot(json["values"].to<JsonObject>(), m5paper_controls::controls, m5paper_controls::count,
        [](const Control& control, Value& value) {
            switch (&control - m5paper_controls::controls) {
            case m5paper_controls::screenSaver: value.text = "media"; return true;
            case m5paper_controls::sleepDelay: value.number = 120; return true;
            case m5paper_controls::slideshowInterval: value.number = 30; return true;
            case m5paper_controls::battery: value.number = 87; return true;
            case m5paper_controls::temperature: value.number = 21.3; return true;
            case m5paper_controls::humidity: return false;  // Unavailable sensor is omitted.
            case m5paper_controls::wifiSignal: value.number = -61; return true;
            default: value.boolean = true; return true;
            }
        });
    std::string out;
    serializeJson(json, out);
    return out;
}

static void snapshotTests() {
    const std::string wire = snapshotJson(false);
    JsonDocument json;
    assert(!deserializeJson(json, wire));
    JsonObject values = json["values"];
    assert(values["slideshow"] == true);
    assert(values["screenSaver"] == "media");
    assert(values["sleepDelay"] == 120 && values["sleepDelay"].is<long>());
    assert(wire.find("\"temperature\":21.3,") != std::string::npos);
    assert(values["humidity"].isUnbound());
    assert(values["restart"].isUnbound() && values["refreshDisplay"].isUnbound());
    assert(json["ok"].isUnbound());
    JsonDocument error;
    writeError(error, errorName(Status::busy));
    std::string errorWire;
    serializeJson(error, errorWire);
    assert(errorWire == R"({"ok":false,"error":"busy"})");
}

static void fragmentTests() {
    assert(packetLimit(23) == 20);
    assert(packetLimit(0) == 20);
    assert(packetLimit(100) == 97);
    assert(packetLimit(517) == safePacketBytes);
    std::string data;
    for (int i = 0; i < 500; ++i) data += char('a' + i % 26);
    for (const size_t limit : {size_t(20), size_t(97), safePacketBytes}) {
        for (const size_t length : {size_t(0), size_t(1), limit - 2, limit - 1, size_t(500)}) {
            std::string reassembled;
            int finals = 0;
            const uint8_t header[] = {snapshotFragment};
            const int packets = sendFragments(header, 1, data.data(), length, limit,
                [&](const uint8_t* packet, size_t size) {
                    assert(size <= limit && size >= 2 && packet[0] == snapshotFragment);
                    assert(finals == 0);
                    if (packet[1] & finalFragment) ++finals;
                    reassembled.append(reinterpret_cast<const char*>(packet + 2), size - 2);
                    return true;
                });
            assert(packets >= 1 && finals == 1);
            assert(reassembled == data.substr(0, length));
            const size_t chunk = limit - 2;
            assert(size_t(packets) == (length == 0 ? 1 : (length + chunk - 1) / chunk));
        }
    }
    const uint8_t relayHeader[] = {relayAction, 7};
    std::string relayed;
    assert(sendFragments(relayHeader, 2, data.data(), 300, 20, [&](const uint8_t* packet, size_t size) {
        assert(packet[0] == relayAction && packet[1] == 7 && size <= 20);
        relayed.append(reinterpret_cast<const char*>(packet + 3), size - 3);
        return true;
    }) == 18);
    assert(relayed == data.substr(0, 300));
    int calls = 0;
    assert(sendFragments(relayHeader, 2, data.data(), 300, 20,
        [&](const uint8_t*, size_t) { return ++calls < 2; }) == -1);
    assert(calls == 2);
    assert(sendFragments(relayHeader, 2, data.data(), 3, 3, [](const uint8_t*, size_t) { return true; }) == -1);
}

static void relayTests() {
    char frame[256];
    const size_t length = writeRelayAction(frame, sizeof(frame), "mac-1",
        R"({"type":"macMedia","text":"playPause"})");
    assert(length > 0 && std::string(frame) ==
        R"({"computerId":"mac-1","body":{"type":"macMedia","text":"playPause"}})");
    assert(writeRelayAction(frame, 16, "mac-1", R"({"type":"x"})") == 0);

    const char* tokens[] = {"alpha", "beta", ""};
    const auto at = [&](size_t index) { return tokens[index]; };
    assert(tokenComputerIndex("beta", 4, "legacy", 3, at) == 1);
    assert(tokenComputerIndex("alpha", 5, "legacy", 3, at) == 0);
    assert(tokenComputerIndex("alph", 4, "legacy", 3, at) == -2);
    assert(tokenComputerIndex("alphax", 6, "legacy", 3, at) == -2);
    assert(tokenComputerIndex("", 0, "", 3, at) == -2);
    assert(tokenComputerIndex("legacy", 6, "legacy", 0, at) == -1);
    assert(tokenComputerIndex("legacy", 6, "legacy", 3, at) == 0);

    RelayRegistry registry;
    assert(registry.find(0) == RelayRegistry::none);
    assert(registry.add(5, 0, RelayRole::forwarder));
    assert(registry.find(0) == 5 && registry.find(0, true) == RelayRegistry::none);
    assert(registry.add(6, 0, RelayRole::computer));
    assert(registry.find(0) == 6 && registry.find(0, true) == 6);
    assert(registry.add(5, 1, RelayRole::forwarder));
    assert(registry.isRelay(5) && registry.isRelay(6) && !registry.isRelay(7));
    assert(registry.add(5, 0, RelayRole::forwarder) && registry.size() == 3);
    registry.removeHandle(6);
    assert(registry.find(0) == 5 && !registry.isRelay(6));
    registry.removeHandle(5);
    assert(registry.size() == 0 && registry.find(1) == RelayRegistry::none);
    for (uint16_t handle = 0; handle < RelayRegistry::capacity; ++handle)
        assert(registry.add(handle, handle, RelayRole::computer));
    assert(!registry.add(100, 0, RelayRole::computer));
    registry.clear();
    assert(registry.size() == 0);

    HandleSet set;
    assert(set.add(1) && set.add(1) && set.size() == 1);
    assert(set.add(2) && set.contains(2));
    set.remove(1);
    assert(!set.contains(1) && set.size() == 1 && set.at(0) == 2);

    RelaySequences sequences;
    const uint8_t first = sequences.next(3);
    const uint8_t second = sequences.next(3);
    assert(first != second);
    assert(sequences.complete(3, second) && !sequences.complete(3, second));
    assert(!sequences.complete(4, first));
    sequences.removeHandle(3);
    assert(!sequences.complete(3, first));
}

static void write(const std::string& path, const std::string& contents) {
    std::ofstream file(path);
    assert(file);
    file << contents;
}

static void descriptorTests(const std::string& directory) {
    JsonDocument paper;
    writeDeviceDescriptor(paper, m5paper(), "papergif-000000000001", "test",
        m5paper_controls::controls, m5paper_controls::count);
    assert(paper["capabilities"]["transports"][0] == "http");
    assert(paper["capabilities"]["transports"][1] == "ble");
    assert(paper["controls"].size() == m5paper_controls::count);
    assert(paper["controls"][m5paper_controls::sleepDelay]["unit"] == "s");
    assert(paper["controls"][m5paper_controls::restart]["confirm"] == true);
    assert(paper["controls"][m5paper_controls::battery]["readOnly"] == true);
    assert(paper["controls"][m5paper_controls::restart]["readOnly"].isUnbound());
    JsonDocument reference;
    writeDeviceDescriptor(reference, esp32Reference(), "papergif-000000000002", "test",
        reference_controls::controls, reference_controls::count);
    assert(reference["controls"].size() == reference_controls::count);
    JsonDocument supermini;
    writeDeviceDescriptor(supermini, paper_board::superminiS3Mt6701(), "papergif-000000000004", "test",
        reference_controls::controls, reference_controls::count);
    assert(supermini["boardID"] == "paperremote.supermini-s3-mt6701");
    assert(supermini["display"].isNull());
    assert(supermini["inputs"][2]["kind"] == "dial");
    assert(supermini["inputs"][2]["minimum"] == 0);
    assert(supermini["inputs"][2]["maximum"] == 16383);
#if defined(PAPERGIF_SUPERMINI_S3)
    assert(reference_controls::count == 16);
    assert(supermini["controls"][reference_controls::dialLowLatency]["kind"] == "toggle");
    assert(supermini["controls"][reference_controls::dialRate]["minimum"] == 15);
    assert(supermini["controls"][reference_controls::dialRate]["maximum"] == 500);
    assert(std::string(supermini["controls"][reference_controls::dialZero]["id"] | "") == "dialZero");
    assert(supermini["controls"][reference_controls::dialMode]["options"].size() == 3);
    assert(supermini["controls"][reference_controls::dialPosition]["readOnly"] == true);
    assert(supermini["controls"][reference_controls::dialTurns]["maximum"] == 100);
    assert(supermini["controls"][reference_controls::dialStep]["minimum"] == 0.01);
    const Control* selected = nullptr;
    Value selectedValue;
    const std::string mode = R"({"id":"dialMode","value":"continuous"})";
    assert(parseSetRequest(mode.c_str(), mode.size(), reference_controls::controls,
        reference_controls::count, selected, selectedValue) == Status::ok);
    assert(!std::strcmp(selectedValue.text, "continuous"));
    // Decimal limits survive ArduinoJson's float storage (0.01 parses as 0.0099999998).
    const struct { const char* request; double expected; } limits[] = {
        {R"({"id":"dialStep","value":0.01})", 0.01}, {R"({"id":"dialStep","value":10})", 10},
        {R"({"id":"dialJitter","value":0.05})", 0.05}, {R"({"id":"dialStart","value":359.9})", 359.9},
        {R"({"id":"dialTurns","value":-0.1})", -0.1}, {R"({"id":"dialSweep","value":-360})", -360},
    };
    for (const auto& limit : limits) {
        assert(parseSetRequest(limit.request, std::strlen(limit.request), reference_controls::controls,
            reference_controls::count, selected, selectedValue) == Status::ok);
        assert(selectedValue.number == limit.expected);
    }
    const std::string below = R"({"id":"dialStep","value":0.0099})";
    assert(parseSetRequest(below.c_str(), below.size(), reference_controls::controls,
        reference_controls::count, selected, selectedValue) == Status::invalidValue);
#endif
    JsonDocument plain;
    writeDeviceDescriptor(plain, m5paper(), "papergif-000000000003", "test");
    assert(plain["controls"].isUnbound() && plain["capabilities"]["transports"].size() == 2);

    std::string wire;
    serializeJson(paper, wire);
    write(directory + "/descriptor-m5paper.json", wire);
    wire.clear();
    serializeJson(reference, wire);
    write(directory + "/descriptor-reference.json", wire);
    wire.clear();
    serializeJson(supermini, wire);
    write(directory + "/descriptor-supermini-s3.json", wire);
    write(directory + "/controls-m5paper-snapshot.json", snapshotJson(false));
    write(directory + "/controls-m5paper-set-response.json", snapshotJson(true));
    char frame[256];
    writeRelayAction(frame, sizeof(frame), "mac-1", R"({"type":"macMedia","text":"playPause"})");
    write(directory + "/controls-relay-action.json", frame);
}

int main(int argc, char** argv) {
    validationTests();
    tableTests();
    snapshotTests();
    fragmentTests();
    relayTests();
    descriptorTests(argc > 1 ? argv[1] : ".pio/host-tests");
    std::puts("device controls tests passed");
}
