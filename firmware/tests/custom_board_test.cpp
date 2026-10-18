#include "../include/descriptor_json.h"
#include "../include/firmware_identity.h"
#include "../include/reference_profile.h"
#include "../include/remote_action_payload.h"
#include "../include/remote_network_queue.h"
#include "../include/simulated_board.h"
#include <cassert>
#include <cstdio>
#include <fstream>
#include <string>
#include <vector>

using namespace paper_board;

static JsonDocument example() {
    JsonDocument json;
    assert(!deserializeJson(json, R"({
        "version":7,"pages":[],
        "hardwareBindings":[
          {"inputID":"encoder-1","event":"rotate","mode":"relative","minimum":0,"maximum":100,"step":5,
           "action":{"type":"macMedia","host":"","text":"volume","value":50,"modifiers":[]}},
          {"inputID":"slider-1","event":"change","mode":"absolute","minimum":10,"maximum":90,"step":10,
           "action":{"type":"wledBrightness","host":"192.168.1.2","text":"","value":10,"modifiers":[]}},
          {"inputID":"button-1","event":"press","mode":"action","minimum":0,"maximum":100,"step":1,
           "action":{"type":"openBuilds","host":"","text":"continuousJogXPositive","value":0,"modifiers":[]}},
          {"inputID":"button-1","event":"release","mode":"action","minimum":0,"maximum":100,"step":1,
           "action":{"type":"openBuilds","host":"","text":"cancelJog","value":0,"modifiers":[]}}
        ]})"));
    return json;
}
static void descriptorTests() {
    for (const auto* board : {&m5paper(), &esp32Reference(), &superminiS3Mt6701()}) {
        JsonDocument json;
        writeDeviceDescriptor(json, *board, "stable-id", "test");
        assert(json["schemaVersion"] == 1 && json["protocolVersion"] == 1);
        assert(json["deviceID"] == "stable-id");
        assert(json["boardID"] == board->id);
        assert(json["hardwareRevision"] == board->revision);
        assert(json["display"].isNull() == !board->display);
        assert(json["inputs"].size() == board->inputCount);
        assert(json["layout"]["inputs"].size() == board->inputCount);
        assert(json["capabilities"]["profileVersions"].size() == (board->profile7 ? 2 : 1));
        assert(json["capabilities"]["media"] == bool(board->display));
        std::string wire;
        serializeJson(json, wire);
        assert(!wire.empty() && wire.size() < maxDescriptorBytes);
        if (!board->display) assert(wire.size() > 512);
        std::string reconstructed;
        for (uint32_t offset = 0; ; offset += descriptorChunkBytes) {
            const size_t size = descriptorSliceLength(wire.size(), offset);
            reconstructed += wire.substr(offset < wire.size() ? offset : wire.size(), size);
            if (size < descriptorChunkBytes) break;
        }
        assert(reconstructed == wire);
    }
    assert(descriptorSliceLength(1024, 512) == 512);
    assert(descriptorSliceLength(1024, 1024) == 0);
    assert(descriptorSliceLength(1024, UINT32_MAX) == 0);
    assert(compatibleFirmware(m5paper(), "m5stack.m5paper", "1.0"));
    assert(!compatibleFirmware(m5paper(), esp32Reference().id, esp32Reference().revision));
    assert(!compatibleFirmware(m5paper(), m5paper().id, "2.0"));
    assert(!compatibleFirmware(m5paper(), nullptr, "1.0"));
    assert(compatibleFirmware(superminiS3Mt6701(), "paperremote.supermini-s3-mt6701", "1"));
    assert(superminiS3Mt6701().inputs[2].maximum == 16383);
    FirmwareIdentityScanner valid, wrong;
    const std::string marker = m5paperFirmwareIdentity;
    for (size_t i = 0; i < marker.size(); ++i)
        valid.append(reinterpret_cast<const uint8_t*>(marker.data() + i), 1);
    wrong.append(reinterpret_cast<const uint8_t*>(referenceFirmwareIdentity),
        std::strlen(referenceFirmwareIdentity));
    assert(valid.compatible() && !wrong.compatible());
}
static void geometryTests() {
    const Rect controls[] = {{0,0,100,100}, {100,100,100,100}};
    for (const auto& size : {std::pair<int,int>{540,960}, {960,540}, {240,240}, {32,16}}) {
        SimulatedDisplay display(size.first, size.second);
        SimulatedBoard board(&display);
        board.begin();
        assert(display.initialized && board.input.initialized);
        display.layout({0,0,200,200}, controls, 2);
        assert(display.count == 2 && display.frames == 1);
        for (size_t i = 0; i < display.count; ++i) {
            const auto r = display.drawn[i];
            assert(validRect(r));
            assert(r.x >= 0 && r.y >= 0);
            assert(r.x + r.width <= size.first && r.y + r.height <= size.second);
            assert(display.hit(r.x + r.width/2, r.y + r.height/2) == int(i));
        }
        assert(display.hit(-1,-1) == -1);
        const unsigned slots[] = {0, 5, 10};
        display.layoutGrid(4, 3, slots, 3);
        assert(display.count == 3);
        for (size_t i = 0; i < display.count; ++i) {
            const auto& r = display.drawn[i];
            assert(validRect(r));
            assert(display.hit(r.x + r.width / 2, r.y + r.height / 2) == int(i));
        }
    }
    const Rect landscapeCell = genericControlRect({0,0,320,240}, 4, 3, 0);
    assert(std::abs(landscapeCell.x - 13.8) < .00001);
    assert(std::abs(landscapeCell.y - 10.6) < .00001);
    assert(std::abs(landscapeCell.width - 71.6) < .00001);
    assert(std::abs(landscapeCell.height - 71.6) < .00001);
    assert(!validRect(genericControlRect({0,0,320,240}, 4, 3, 3, 2)));
    SimulatedBoard screenless(nullptr);
    screenless.begin();
    assert(!screenless.display() && screenless.input.initialized);
    assert(!validRect(fit({0,0,0,10}, {0,0,10,10})));
    assert(!validRect(fit({0,0,NAN,10}, {0,0,10,10})));
    for (int rotation : {0, 90, 180, 270}) {
        SimulatedDisplay rotated(320, 240, rotation);
        assert(rotated.info()->rotation == rotation);
        rotated.layout({0,0,200,200}, controls, 2);
        assert(rotated.hit(rotated.drawn[0].x + 1, rotated.drawn[0].y + 1) == 0);
    }
}
static void bindingTests() {
    auto json = example();
    NativeProfile profile;
    assert(parseNativeProfile(json, profile, esp32Reference()));
    assert(profile.count == 4);
    std::vector<NativeAction> actions;
    auto dispatch = [&](const HardwareBinding&, const NativeAction& action) {
        actions.push_back(action); return true;
    };
    SimulatedBoard board(nullptr);
    board.begin();
    board.input.push({"encoder-1","rotate",3,1});
    board.input.push({"encoder-1","rotate",-2,2});
    board.input.push({"encoder-1","rotate",-2,2}); // duplicate
    board.input.push({"encoder-1","rotate",100,3});
    board.input.push({"encoder-1","rotate",-100,4});
    board.input.push({"encoder-1","rotate",NAN,5});
    board.input.push({"slider-1","change",2048,6});
    board.input.push({"slider-1","change",99999,7});
    board.input.push({"slider-1","change",-999,8});
    InputEvent event;
    while (board.input.poll(event)) dispatchHardwareInput(profile, board.info(), event, dispatch);
    assert(actions.size() == 7);
    // Media volume percent (65, 55, 100, 0) is sent on the 0-255 media wire scale.
    assert(actions[0].value == 166 && actions[1].value == 140);
    assert(actions[2].value == 255 && actions[3].value == 0);
    assert(actions[0].valueTenths == 650);
    assert(actions[4].value == 50 && actions[5].value == 90 && actions[6].value == 10);
    for (uint32_t i = 9; i < 10009; ++i)
        dispatchHardwareInput(profile, board.info(), {"encoder-1","rotate",i % 2 ? 1.0 : -1.0,i}, dispatch);
    assert(actions.back().value >= 0 && actions.back().value <= 255);
    NativeAction media{};
    std::strcpy(media.type, "iPhoneMedia"); std::strcpy(media.text, "volume");
    assert(mediaWireValue(media, 100) == 255 && mediaWireValue(media, 0) == 0);
    std::strcpy(media.type, "wledBrightness");
    assert(mediaWireValue(media, 100) == 100);
    const auto before = actions.size();
    bool pressed[] = {true,false,false};
    releaseHardwareInputs(profile, board.info(), pressed, dispatch);
    assert(!pressed[0] && actions.size() == before + 2);
    assert(!std::strcmp(actions.back().text, "cancelJog"));
    releaseHardwareInputs(profile, board.info(), pressed, dispatch);
    assert(actions.size() == before + 2);
    board.input.release();
    assert(board.input.released);
    JsonDocument body;
    writeRemoteActionPayload(body, actions.back());
    assert(body["type"] == "openBuilds" && body["text"] == "cancelJog");
    assert(body["valueTenths"] == 0);
    BindingState wrapped;
    wrapped.seen = true; wrapped.sequence = UINT32_MAX;
    double value;
    assert(applyInput(wrapped, esp32Reference().inputs[0], {"button-1","press",1,0}, value));
    assert(!applyInput(wrapped, esp32Reference().inputs[0], {"button-1","press",1,UINT32_MAX}, value));
    profile.count = 3; // No explicit release binding: continuous jog still must stop.
    const auto atRelease = actions.size();
    dispatchHardwareInput(profile, board.info(), {"button-1","press",1,10010}, dispatch);
    dispatchHardwareInput(profile, board.info(), {"button-1","release",0,10011}, dispatch);
    dispatchHardwareInput(profile, board.info(), {"button-1","release",0,10011}, dispatch);
    assert(actions.size() == atRelease + 2);
    assert(!std::strcmp(actions.back().text, "cancelJog"));
}
static void parserTests() {
    NativeProfile output;
    auto json = example();
    json["version"] = 6;
    assert(!parseNativeProfile(json, output, esp32Reference()));
    json.remove("hardwareBindings");
    assert(parseNativeProfile(json, output, esp32Reference()));
    json = example();
    json["hardwareBindings"][0]["inputID"] = "invented";
    assert(!parseNativeProfile(json, output, esp32Reference()));
    json = example();
    json["hardwareBindings"][0]["step"] = 0;
    assert(!parseNativeProfile(json, output, esp32Reference()));
    json = example();
    json["hardwareBindings"][0]["minimum"] = 101;
    assert(!parseNativeProfile(json, output, esp32Reference()));
    json = example();
    json["hardwareBindings"][0]["event"] = "change";
    assert(!parseNativeProfile(json, output, esp32Reference()));
    json = example();
    json["hardwareBindings"][0]["action"]["type"] = "unsupported";
    const char* reason = nullptr;
    assert(!parseNativeProfile(json, output, esp32Reference(), &reason));
    assert(!std::strcmp(reason, "unsupported_action"));
    json = example();
    json["hardwareBindings"][0]["mode"] = "action";
    json["hardwareBindings"][0]["direction"] = "negative";
    auto other = json["hardwareBindings"].as<JsonArray>().add<JsonObject>();
    other.set(json["hardwareBindings"][0]);
    other["direction"] = "positive";
    assert(parseNativeProfile(json, output, esp32Reference()));
    int dispatched = 0;
    dispatchHardwareInput(output, esp32Reference(), {"encoder-1","rotate",-1,1},
        [&](const HardwareBinding& binding, const NativeAction&) {
            assert(binding.direction == -1); ++dispatched; return true;
        });
    dispatchHardwareInput(output, esp32Reference(), {"encoder-1","rotate",1,2},
        [&](const HardwareBinding& binding, const NativeAction&) {
            assert(binding.direction == 1); ++dispatched; return true;
        });
    assert(dispatched == 2);
    other.remove("direction");
    assert(!parseNativeProfile(json, output, esp32Reference()));
    json = example();
    json["hardwareBindings"][0]["action"]["type"] = "iPhoneMedia";
    assert(parseNativeProfile(json, output, esp32Reference()));
    json["hardwareBindings"][0]["action"]["text"] = "playPause";
    assert(!parseNativeProfile(json, output, esp32Reference()));
    json = example();
    json["hardwareBindings"][0]["action"]["text"] = "seek";
    assert(!parseNativeProfile(json, output, esp32Reference()));
    json = example();
    json["hardwareBindings"][0]["maximum"] = 101;
    assert(!parseNativeProfile(json, output, esp32Reference()));
}
int main(int argc, char** argv) {
    descriptorTests();
    geometryTests();
    bindingTests();
    parserTests();
    if (argc > 1) {
        std::ifstream file(argv[1]);
        JsonDocument fixture;
        assert(file && !deserializeJson(fixture, file));
        NativeProfile parsed;
        assert(parseNativeProfile(fixture, parsed, esp32Reference()));
        assert(parsed.count == 3);
    }
    if (argc > 2) {
        std::ifstream file(argv[2]);
        JsonDocument fixture;
        assert(file && !deserializeJson(fixture, file));
        assert(fixture["boardID"] == esp32Reference().id);
        assert(fixture["hardwareRevision"] == esp32Reference().revision);
        for (auto& input : {esp32Reference().inputs[0], esp32Reference().inputs[1], esp32Reference().inputs[2]}) {
            bool found = false;
            for (JsonObjectConst item : fixture["inputs"].as<JsonArrayConst>())
                found = found || item["id"] == input.id;
            assert(found);
        }
    }
    if (argc > 3) {
        std::ifstream file(argv[3]);
        JsonDocument fixture;
        assert(file && !deserializeJson(fixture, file));
        SimulatedDisplay landscape(fixture["display"]["width"], fixture["display"]["height"]);
        assert(landscape.info()->width == 320 && landscape.info()->height == 240);
        const unsigned slots[] = {0, 5, 10};
        landscape.layoutGrid(4, 3, slots, 3);
        assert(landscape.hit(14, 11) == 0);
        bool testedDial = false;
        for (JsonObjectConst item : fixture["inputs"].as<JsonArrayConst>()) {
            if (item["kind"] != "dial") continue;
            InputInfo dial{item["id"], item["name"], "dial", {"change", nullptr, nullptr}, {},
                item["minimum"], item["maximum"]};
            BindingState state;
            state.mode = BindingMode::absolute;
            double value = -1;
            assert(applyInput(state, dial, {dial.id, "change", dial.minimum, 1}, value) && value == 0);
            assert(applyInput(state, dial, {dial.id, "change", dial.maximum, 2}, value) && value == 100);
            testedDial = true;
        }
        assert(testedDial);
    }
    puts("custom board descriptor, geometry, profile, and input tests passed");
}
