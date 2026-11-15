#include "../include/descriptor_json.h"
#include "../include/firmware_identity.h"
#include "../include/reference_profile.h"
#include "../include/reference_pages.h"
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
    for (const auto* board : {&m5paper(), &esp32Reference(), &superminiS3Mt6701(), &waveshareAmoled18V2()}) {
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
        assert(json["capabilities"]["media"] == board->legacyMedia);
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
    assert(m5paper().legacyMedia);
    assert(!esp32Reference().legacyMedia && !superminiS3Mt6701().legacyMedia);
    const auto& amoled = waveshareAmoled18V2();
    assert(compatibleFirmware(amoled, "paperremote.waveshare-amoled-18-v2", "2"));
    assert(!std::strcmp(waveshareAmoled18FirmwareIdentity, "PGIFBOARD:paperremote.waveshare-amoled-18-v2@2;"));
    assert(amoled.display && amoled.display->width == 368 && amoled.display->height == 448);
    assert(amoled.display->touch && !std::strcmp(amoled.display->pixelFormat, "rgb565"));
    assert(!amoled.legacyMedia && amoled.inputCount == 3 && amoled.inputs[2].maximum == 16383);
    assert(!std::strcmp(amoled.inputs[0].id, "button-1") && !std::strcmp(amoled.inputs[2].id, "dial-1"));
    assert(amoled.inputs[0].bounds.x == 24 && amoled.inputs[0].bounds.y == 360);
    assert(amoled.inputs[1].bounds.x == 196 && amoled.inputs[1].bounds.width == 148);
    assert(amoled.inputs[2].bounds.x == 64 && amoled.inputs[2].bounds.width == 240);
    assert(amoled.screen.width == 368 && amoled.screen.height == 448);
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
    assert(parseNativeProfile(json, output, esp32Reference()));
    json = example();
    json["hardwareBindings"][0]["maximum"] = 101;
    assert(!parseNativeProfile(json, output, esp32Reference()));
}
static void pageBindingTests() {
    auto json = example();
    json["hardwareBindings"].as<JsonArray>().remove(1);
    json["hardwareBindings"].as<JsonArray>().remove(0);
    auto first = json["pages"].as<JsonArray>().add<JsonObject>();
    first["id"] = "page-a";
    first["controls"].to<JsonArray>();
    auto second = json["pages"].as<JsonArray>().add<JsonObject>();
    second["id"] = "page-b";
    second["controls"].to<JsonArray>();
    json["hardwareBindings"][0]["pageID"] = "page-a";
    json["hardwareBindings"][1]["pageID"] = "page-a";
    auto other = json["hardwareBindings"].as<JsonArray>().add<JsonObject>();
    other.set(json["hardwareBindings"][0]);
    other["pageID"] = "page-b";
    other["action"]["type"] = "macMedia";
    other["action"]["text"] = "playPause";
    NativeProfile profile;
    assert(parseNativeProfile(json, profile, waveshareAmoled18V2()));
    int dispatched = 0;
    std::strcpy(profile.activePageID, "page-b");
    dispatchHardwareInput(profile, waveshareAmoled18V2(), {"button-1", "press", 1, 1},
        [&](const HardwareBinding& binding, const NativeAction& action) {
            assert(!std::strcmp(binding.pageID, "page-b"));
            assert(!std::strcmp(action.text, "playPause"));
            ++dispatched;
            return true;
        });
    assert(dispatched == 1);
    bool pressed[] = {true, false, false};
    releaseHardwareInputs(profile, waveshareAmoled18V2(), pressed,
        [&](const HardwareBinding&, const NativeAction&) { ++dispatched; return true; });
    assert(dispatched == 1);
    other["pageID"] = "missing";
    assert(!parseNativeProfile(json, profile, waveshareAmoled18V2()));
    other["pageID"] = "page-b";
    other["inputID"] = "dial-1";
    other["event"] = "change";
    other["mode"] = "absolute";
    other["controlID"] = "volume-tile";
    auto tile = second["controls"].as<JsonArray>().add<JsonObject>();
    tile["id"] = "volume-tile";
    tile["kind"] = "slider";
    tile["action"].set(other["action"]);
    tile["action"]["text"] = "volume";
    tile["action"]["value"] = 128;
    assert(parseNativeProfile(json, profile, waveshareAmoled18V2()));
    assert(profile.bindings[2].state.value == 50);
    std::strcpy(profile.activePageID, "page-b");
    dispatchHardwareInput(profile, waveshareAmoled18V2(), {"dial-1", "change", 16383, 2},
        [&](const HardwareBinding& binding, const NativeAction& action) {
            assert(!std::strcmp(binding.controlID, "volume-tile"));
            assert(!std::strcmp(action.text, "volume") && action.value == 255);
            ++dispatched;
            return true;
        });
    assert(dispatched == 2);
    assert(hasSliderDialBinding(profile));
    profile.bindings[profile.count] = profile.bindings[0];
    profile.bindings[profile.count++].pageID[0] = 0;
    profile.bindings[profile.count] = profile.bindings[2];
    profile.bindings[profile.count].controlID[0] = 0;
    profile.bindings[profile.count++].pageID[0] = 0;
    std::strcpy(profile.activePageID, "unassigned-page");
    dispatchHardwareInput(profile, waveshareAmoled18V2(), {"button-1", "press", 1, 3},
        [&](const HardwareBinding&, const NativeAction&) { ++dispatched; return true; });
    dispatchHardwareInput(profile, waveshareAmoled18V2(), {"dial-1", "change", 0, 4},
        [&](const HardwareBinding&, const NativeAction&) { ++dispatched; return true; });
    pressed[0] = true;
    releaseHardwareInputs(profile, waveshareAmoled18V2(), pressed,
        [&](const HardwareBinding&, const NativeAction&) { ++dispatched; return true; });
    assert(dispatched == 2);
    assert(!hasSliderDialBinding(profile));
    std::strcpy(profile.activePageID, "page-b");
    dispatchHardwareInput(profile, waveshareAmoled18V2(), {"dial-1", "change", 0, 5},
        [&](const HardwareBinding& binding, const NativeAction&) {
            assert(!std::strcmp(binding.pageID, "page-b"));
            ++dispatched;
            return true;
        });
    assert(dispatched == 3);
    tile["kind"] = "button";
    assert(!parseNativeProfile(json, profile, waveshareAmoled18V2()));
    other["controlID"] = "missing";
    assert(!parseNativeProfile(json, profile, waveshareAmoled18V2()));
}

static void seekTransitionTests() {
    PageMediaState media;
    assert(media.ignoresKnobSeek(100));
    JsonDocument track;
    track["available"] = true;
    track["playing"] = true;
    track["text"] = "First track";
    track["elapsedMilliseconds"] = 30000;
    track["durationMilliseconds"] = 180000;
    assert(media.update(track.as<JsonObjectConst>(), 100));
    assert(media.ignoresKnobSeek(1099));
    assert(!media.ignoresKnobSeek(1100));
    media.noteTrackChange(2000);
    assert(media.ignoresKnobSeek(2001));
    assert(media.update(track.as<JsonObjectConst>(), 2500));
    assert(media.ignoresKnobSeek(6999));
    assert(!media.ignoresKnobSeek(7000));
    media.noteTrackChange(8000);
    track["text"] = "Second track";
    track["elapsedMilliseconds"] = 0;
    assert(media.update(track.as<JsonObjectConst>(), 8200));
    assert(media.ignoresKnobSeek(9199));
    assert(!media.ignoresKnobSeek(9200));
    track["elapsedMilliseconds"] = 1000;
    assert(media.update(track.as<JsonObjectConst>(), 9300));
    assert(!media.ignoresKnobSeek(9300));
    track["elapsedMilliseconds"] = 180000;
    assert(media.update(track.as<JsonObjectConst>(), 10000));
    assert(media.ignoresKnobSeek(10001));
    track["text"] = "Automatic next track";
    track["elapsedMilliseconds"] = 0;
    assert(media.update(track.as<JsonObjectConst>(), 10100));
    assert(media.ignoresKnobSeek(11099));
    assert(!media.ignoresKnobSeek(11100));
    media.timeline.stale = true;
    assert(media.ignoresKnobSeek(11200));
}

static void pageLayoutTests() {
    JsonDocument json;
    assert(!deserializeJson(json, R"({"gridColumns":2,"gridRows":4,"controls":[
        {"kind":"button","layoutSlot":0}, {"kind":"slider","layoutSlot":1},
        {"kind":"button","gridWidth":2,"gridHeight":2,"layoutSlot":4}]})"));
    PageTilePlacement placements[maxPageTiles];
    assert(layoutPageTiles(json.as<JsonObjectConst>(), placements));
    assert(placements[0].slot == 0 && placements[0].height == 2);
    assert(placements[1].slot == 1 && placements[1].height == 1);
    assert(placements[2].slot == 4 && placements[2].width == 2);
    for (size_t index = 0; index < 3; ++index) {
        const auto rect = pageTileRect(placements[index], 2, 4, 368, 448);
        assert(validRect(rect) && rect.y > pageHeaderHeight);
        assert(rect.x + rect.width <= 368 && rect.y + rect.height <= 448);
    }
    json["controls"][1]["layoutSlot"] = 0;
    assert(layoutPageTiles(json.as<JsonObjectConst>(), placements));
    assert(placements[1].slot == 1);
    json["gridRows"] = 1;
    assert(!layoutPageTiles(json.as<JsonObjectConst>(), placements));
    PageSwipe swipe;
    swipe.begin(100, 200, false);
    assert(swipe.move(40, 205) == 1 && swipe.swiped);
    swipe.begin(100, 200, true);
    assert(swipe.move(40, 205) == 0 && !swipe.swiped);
    swipe.begin(100, 200, false);
    assert(swipe.move(110, 280) == 0 && !swipe.swiped);
}

int main(int argc, char** argv) {
    descriptorTests();
    geometryTests();
    bindingTests();
    parserTests();
    pageBindingTests();
    seekTransitionTests();
    pageLayoutTests();
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
