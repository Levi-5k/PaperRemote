#include "waveshare_amoled_18_board.h"
#include "descriptor_json.h"
#include "firmware_identity.h"
#include "reference_controls.h"
#include "remote_computer.h"
#include "local_http_policy.h"
#include "remote_action_payload.h"
#include "dial_stream.h"
#include "bluetooth.h"
#include "profile_store.h"
#include "media_store.h"
#include "network.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "esp_system.h"
#include "esp_random.h"
#include "nvs_flash.h"
#include "driver/sdmmc_host.h"
#include "esp_vfs_fat.h"
#include "sdmmc_cmd.h"
#include "lwip/inet.h"
#include "lwip/sockets.h"
#include <memory>
#include <sys/stat.h>

namespace {
using namespace paper_board;
using namespace native_device;
WaveshareAmoled18Board board;
ProfileStore profile;
MediaStore images;
sdmmc_card_t* mediaCard = nullptr;
size_t saverOffset = 0;
nvs_handle_t imageStorage = 0;
bool saverEnabled = true, saverActive = false;
uint32_t saverDelay = 60, saverInterval = 30, lastActivity = 0, saverStartedAt = 0;
char wakeButton[32]{};
void displayActivity() { lastActivity = hardware::millisNow(); saverActive = false; }
bool mountMediaCard() {
    uint8_t output = 0, configuration = 0;
    if (!hardware::readRegister(0x20, 1, &output, 1) ||
        !hardware::readRegister(0x20, 3, &configuration, 1) ||
        !hardware::writeRegister(0x20, 1, output | 0x80) ||
        !hardware::writeRegister(0x20, 3, configuration & ~0x80)) return false;
    sdmmc_host_t host = SDMMC_HOST_DEFAULT();
    host.flags = SDMMC_HOST_FLAG_1BIT;
    sdmmc_slot_config_t slot = SDMMC_SLOT_CONFIG_DEFAULT();
    slot.width = 1;
    slot.clk = GPIO_NUM_2;
    slot.cmd = GPIO_NUM_1;
    slot.d0 = GPIO_NUM_3;
    slot.flags |= SDMMC_SLOT_FLAG_INTERNAL_PULLUP;
    esp_vfs_fat_sdmmc_mount_config_t mount{};
    mount.format_if_mount_failed = false;
    mount.max_files = 5;
    const esp_err_t result = esp_vfs_fat_sdmmc_mount("/sdcard", &host, &slot, &mount, &mediaCard);
    if (result != ESP_OK) {
        mediaCard = nullptr;
        ESP_LOGW("media", "SD card unavailable (%s); using internal storage", esp_err_to_name(result));
        return false;
    }
    struct stat info{};
    if (mkdir("/sdcard/paperGIF", 0775) &&
        (stat("/sdcard/paperGIF", &info) || !S_ISDIR(info.st_mode))) {
        esp_vfs_fat_sdcard_unmount("/sdcard", mediaCard);
        mediaCard = nullptr;
        return false;
    }
    ESP_LOGI("media", "SD card mounted without formatting; media at /sdcard/paperGIF");
    return true;
}
device_controls::RelayRegistry relays;
device_controls::RelaySequences relaySequences;
device_controls::HandleSet subscribers;
uint16_t phone = noConnection;
struct MediaSource : MediaSynchronization {
    PageMediaState state;
};
MediaSource computerMedia[9];
PageMediaState phoneMedia;
bool mediaPending = false;
uint32_t mediaRequestedAt = 0;
uint8_t nextMediaSlot = 0;
bool pressed[8]{};
InputEvent lastInput{};
bool hasLastInput = false, storageReady = false, restartPending = false;
nvs_handle_t dialStorage = 0;
uint32_t restartAt = 0, snapshotAt = 0;
std::string lastSnapshot, relayProfileKeys;
std::unique_ptr<HardwareBinding> touchJog;
dial_stream::Pacer livePacer, phonePacer;
uint8_t phonePacket[3]{};
struct PendingRelay {
    bool active = false;
    int computer = -1;
    std::string key, body;
    uint32_t sentAt = 0;
} pendingRelay;

bool packet(uint16_t handle, const uint8_t* bytes, size_t length) {
    for (int attempt = 0; attempt < 10; ++attempt) {
        if (notify(handle, bytes, length)) return true;
        hardware::wait(5);
    }
    return false;
}
bool fragments(uint16_t handle, const uint8_t* header, size_t headerSize, const std::string& json) {
    return device_controls::sendFragments(header, headerSize, json.data(), json.size(),
        std::min(device_controls::safePacketBytes, notificationCapacity(handle)),
        [handle](const uint8_t* bytes, size_t length) { return packet(handle, bytes, length); }) > 0;
}
bool relayAction(int computer, bool direct, const char* body) {
    const uint16_t handle = relays.find(computer, direct);
    if (handle == device_controls::RelayRegistry::none) return false;
    JsonDocument json;
    json["computerId"] = computer >= 0 ? (profile.json["computers"][computer]["id"] | "") : "";
    json["body"] = serialized(body);
    std::string encoded;
    serializeJson(json, encoded);
    const uint8_t header[] = {device_controls::relayAction, relaySequences.next(handle)};
    return fragments(handle, header, sizeof(header), encoded);
}
void flushRelay(bool force) {
    if (!pendingRelay.active || (!force && hardware::millisNow() - pendingRelay.sentAt < 40)) return;
    pendingRelay.active = false;
    pendingRelay.sentAt = hardware::millisNow();
    relayAction(pendingRelay.computer, false, pendingRelay.body.c_str());
}
bool localAuthority(const char* raw, std::string& authority) {
    authority = raw;
    if (authority.compare(0, 7, "http://") == 0) authority.erase(0, 7);
    while (!authority.empty() && authority.back() == '/') authority.pop_back();
    if (authority.empty() || authority.find_first_of("/@?#\r\n") != std::string::npos) return false;
    std::string host = authority;
    const auto colon = host.find(':');
    if (colon != std::string::npos) {
        const auto port = host.substr(colon + 1);
        if (port.empty() || port.size() > 5 || port.find_first_not_of("0123456789") != std::string::npos ||
            std::atoi(port.c_str()) < 1 || std::atoi(port.c_str()) > 65535) return false;
        host.resize(colon);
    }
    in_addr ip{};
    const auto* bytes = reinterpret_cast<const uint8_t*>(&ip.s_addr);
    return (inet_pton(AF_INET, host.c_str(), &ip) == 1 && local_http::isPrivateIPv4(bytes[0], bytes[1])) ||
        local_http::isLocalHostname(host.c_str());
}
const char* computerToken(int index) {
    return index < 0 ? profile.json["macToken"] | "" : profile.json["computers"][index]["token"] | "";
}
bool computerEndpoint(int index, std::string& authority, int& port) {
    if (index < -1 || index >= 8) return false;
    const char* host = index < 0 ? profile.json["macHost"] | "" : profile.json["computers"][index]["host"] | "";
    port = index < 0 ? profile.json["macPort"] | 43821 : profile.json["computers"][index]["port"] | 43821;
    return computerToken(index)[0] && port > 0 && port <= 65535 && localAuthority(host, authority) &&
        authority.find(':') == std::string::npos;
}
const PageMediaState* mediaState(const NativeAction& action) {
    if (!std::strcmp(action.type, "iPhoneMedia")) return &phoneMedia;
    if (std::strcmp(action.type, "macMedia")) return nullptr;
    const int index = nativeComputerIndex(profile.json.as<JsonVariantConst>(), action.computerId);
    return index >= -1 && index < 8 ? &computerMedia[index + 1].state : nullptr;
}
std::string mediaID(int index) {
    return computerMedia[index + 1].subscriptionID(profile.generation(), index);
}
bool applyMediaItems(JsonVariantConst response, int index, uint32_t now) {
    const auto expected = mediaID(index);
    auto& source = computerMedia[index + 1];
    if (!source.state.updateItems(response, expected.c_str(), now)) return false;
    source.updatedAt = now;
    return true;
}
void pollMedia() {
    const uint32_t now = hardware::millisNow();
    MediaResult* result = nullptr;
    while (takeMediaResult(result)) {
        mediaPending = false;
        if (result->success && result->profileRevision == profile.generation() &&
            result->computer >= -1 && result->computer < 8 &&
            computerMedia[result->computer + 1].acceptsPoll(result->epoch, result->startedAt)) {
            JsonDocument response;
            if (!deserializeJson(response, result->body, result->length))
                applyMediaItems(response.as<JsonVariantConst>(), result->computer, result->receivedAt);
        }
        delete result;
    }
    auto expire = [now](PageMediaState& state, uint32_t timeout) {
        if (!state.timeline.stale && now - state.timeline.sampledAt > timeout) {
            state.timeline.elapsedMilliseconds = media_timeline::elapsedAt(state.timeline, now);
            state.timeline.sampledAt = now;
            state.timeline.stale = true;
        }
    };
    for (auto& source : computerMedia) expire(source.state, 8000);
    expire(phoneMedia, 15000);
    if (mediaPending && now - mediaRequestedAt < 10000) return;
    if (!connected() || !profile.ready() || profile.busy()) return;
    bool needed[9]{};
    for (JsonObjectConst tile : profile.json["pages"][profile.pageIndex()]["controls"].as<JsonArrayConst>()) {
        JsonObjectConst action = tile["action"];
        if (std::strcmp(action["type"] | "", "macMedia")) continue;
        const int index = nativeComputerIndex(profile.json.as<JsonVariantConst>(), action["computerID"] | "");
        if (index >= -1 && index < 8) needed[index + 1] = true;
    }
    for (int offset = 0; offset < 9; ++offset) {
        const int index = (nextMediaSlot + offset) % 9 - 1;
        auto& source = computerMedia[index + 1];
        if (!needed[index + 1] || int32_t(now - source.pollAt) < 0) continue;
        source.pollAt = now + 2000;
        std::string authority;
        int port = 0;
        if (!computerEndpoint(index, authority, port)) continue;
        ActionRequest request;
        const auto url = "http://" + authority + ":" + std::to_string(port) + "/text-source";
        const char* token = computerToken(index);
        if (url.size() >= sizeof(request.url) || std::strlen(token) >= sizeof(request.token)) continue;
        strlcpy(request.url, url.c_str(), sizeof(request.url));
        strlcpy(request.token, token, sizeof(request.token));
        JsonDocument query;
        auto item = query["items"].to<JsonArray>().add<JsonObject>();
        item["id"] = mediaID(index);
        item["source"] = "nowPlaying";
        item["sourceText"] = "";
        item["placeholder"] = "";
        serializeJson(query, request.body, sizeof(request.body));
        request.profileRevision = profile.generation();
        request.mediaEpoch = source.epoch;
        request.relayComputer = index;
        if (enqueueMediaQuery(request)) {
            mediaPending = true;
            mediaRequestedAt = now;
            nextMediaSlot = (index + 2) % 9;
        }
        return;
    }
}
bool dispatchRaw(const HardwareBinding& binding, const NativeAction& action, bool safety) {
    const std::string key = binding.controlID[0] ? std::string(binding.pageID) + ":" + binding.controlID : binding.inputID;
    const auto* playback = !std::strcmp(action.text, "seek") ? mediaState(action) : nullptr;
    const bool finishTrack = playback && media_timeline::seekFinishesTrack(playback->timeline, action.value);
    const bool slider = binding.state.mode != BindingMode::action && !safety && !finishTrack;
    const bool lowLatency = slider && !std::strcmp(binding.inputID, "dial-1");
    if (!slider) { flushStream(false); phonePacer.reset(); }
    if (!std::strcmp(action.type, "iPhoneMedia")) {
        if (phone == noConnection) return false;
        const char* commands[] = {"playPause", "previous", "next", "volumeUp", "volumeDown", "mute", "seek", "volume"};
        for (uint8_t index = 0; index < sizeof(commands) / sizeof(commands[0]); ++index) {
            if (std::strcmp(finishTrack ? "next" : action.text, commands[index])) continue;
            const uint8_t response[] = {0x60, uint8_t(index + 1), uint8_t(std::clamp(action.value, int32_t(0), int32_t(255)))};
            if (lowLatency) { std::memcpy(phonePacket, response, sizeof(response)); phonePacer.offer(); return true; }
            return packet(phone, response, sizeof(response));
        }
        return false;
    }
    JsonDocument json;
    std::string authority, url, body;
    const char* token = "";
    const char* method = "POST";
    int computerIndex = -3, port = 0;
    if (!std::strcmp(action.type, "localHTTP")) {
        if (!localAuthority(action.host, authority) || !local_http::isAllowedPath(action.text) ||
            !local_http::isAllowedMethod(action.httpMethod)) return false;
        url = "http://" + authority + action.text;
        method = action.httpMethod;
        if (!std::strcmp(method, "POST")) body = action.httpBody;
    } else if (!std::strncmp(action.type, "wled", 4)) {
        if (!localAuthority(action.host, authority)) return false;
        url = "http://" + authority + "/json/state";
        if (!std::strcmp(action.type, "wledPower")) {
            if (!std::strcmp(action.text, "on")) json["on"] = true;
            else if (!std::strcmp(action.text, "off")) json["on"] = false;
            else json["on"] = "t";
        } else if (!std::strcmp(action.type, "wledPreset")) json["ps"] = std::clamp(action.value, int32_t(1), int32_t(250));
        else json["bri"] = std::clamp(action.value, int32_t(0), int32_t(255));
    } else {
        computerIndex = nativeComputerIndex(profile.json.as<JsonVariantConst>(), action.computerId);
        if (!computerEndpoint(computerIndex, authority, port)) return false;
        token = computerToken(computerIndex);
        url = "http://" + authority + ":" + std::to_string(port) + "/action";
        writeRemoteActionPayload(json, action);
        if (finishTrack) { json["text"] = "next"; json["value"] = 0; }
    }
    if (std::strcmp(action.type, "localHTTP")) serializeJson(json, body);
    if (computerIndex != -3 && !connected() && relays.find(computerIndex, false) != device_controls::RelayRegistry::none) {
        if (pendingRelay.active && (!slider || pendingRelay.key != key || pendingRelay.computer != computerIndex)) flushRelay(true);
        if (slider) {
            pendingRelay.active = true;
            pendingRelay.computer = computerIndex;
            pendingRelay.key = key;
            pendingRelay.body = body;
            flushRelay(false);
            return true;
        }
        if (relayAction(computerIndex, false, body.c_str())) return true;
    }
    ActionRequest request;
    if (url.size() >= sizeof(request.url) || body.size() >= sizeof(request.body) ||
        std::strlen(token) >= sizeof(request.token)) return false;
    strlcpy(request.url, url.c_str(), sizeof(request.url));
    strlcpy(request.body, body.c_str(), sizeof(request.body));
    strlcpy(request.token, token, sizeof(request.token));
    strlcpy(request.method, method, sizeof(request.method));
    strlcpy(request.controlId, key.c_str(), sizeof(request.controlId));
    request.slider = slider;
    request.profileRevision = profile.generation();
    request.relayComputer = computerIndex;
    if (computerIndex != -3 && lowLatency && streamAction(authority.c_str(), port, request)) return true;
    return enqueueAction(request, safety);
}
bool dispatch(const HardwareBinding& binding, const NativeAction& action, bool safety = false) {
    const uint32_t now = hardware::millisNow();
    PageMediaState* playback = nullptr;
    if (!std::strcmp(action.type, "iPhoneMedia")) playback = &phoneMedia;
    else if (!std::strcmp(action.type, "macMedia")) {
        const int index = nativeComputerIndex(profile.json.as<JsonVariantConst>(), action.computerId);
        if (index >= -1 && index < 8) playback = &computerMedia[index + 1].state;
    }
    const bool seek = !std::strcmp(action.text, "seek");
    if (playback && seek && !std::strcmp(binding.inputID, "dial-1") &&
        playback->ignoresKnobSeek(now)) return false;
    const bool changingTrack = playback && (!std::strcmp(action.text, "next") ||
        !std::strcmp(action.text, "previous") ||
        (seek && media_timeline::seekFinishesTrack(playback->timeline, action.value)));
    const bool sent = dispatchRaw(binding, action, safety);
    if (sent && playback) {
        if (changingTrack) playback->noteTrackChange(now);
        else if (seek) playback->noteLocalSeek(now);
    }
    if (sent && !std::strcmp(action.type, "macMedia") &&
        (!std::strcmp(action.text, "seek") || !std::strcmp(action.text, "playPause") ||
         !std::strcmp(action.text, "previous") || !std::strcmp(action.text, "next"))) {
        const int index = nativeComputerIndex(profile.json.as<JsonVariantConst>(), action.computerId);
        if (index >= -1 && index < 8) {
            auto& source = computerMedia[index + 1];
            source.command(hardware::millisNow());
        }
    }
    return sent;
}
void updateTile(const HardwareBinding& binding, const NativeAction& action) {
    if (!binding.controlID[0] || binding.state.mode == BindingMode::action) return;
    for (JsonObject page : profile.json["pages"].as<JsonArray>()) {
        if (std::strcmp(page["id"] | "", binding.pageID)) continue;
        for (JsonObject tile : page["controls"].as<JsonArray>()) {
            if (std::strcmp(tile["id"] | "", binding.controlID)) continue;
            tile["action"]["value"] = action.value;
            tile["action"]["valueTenths"] = action.valueTenths;
        }
    }
    for (size_t index = 0; index < profile.bindings().count; ++index) {
        auto& linked = profile.bindings().bindings[index];
        if (std::strcmp(linked.pageID, binding.pageID) || std::strcmp(linked.controlID, binding.controlID)) continue;
        linked.state.value = boundValue(nativeControlValue(action), linked.state);
        linked.state.remainder = 0;
        linked.localValueAt = hardware::millisNow();
        linked.hasLocalValue = true;
        if (const auto* media = mediaState(linked.action)) linked.mediaTrackRevision = media->trackRevision;
    }
}
void cancelJog() {
    if (!touchJog) return;
    strlcpy(touchJog->action.text, "cancelJog", sizeof(touchJog->action.text));
    dispatch(*touchJog, touchJog->action, true);
    touchJog.reset();
}
void releaseInputs() {
    flushRelay(true);
    flushStream();
    if (phonePacer.active() && phone != noConnection) packet(phone, phonePacket, sizeof(phonePacket));
    phonePacer.reset();
    clearActions();
    cancelJog();
    if (profile.ready()) releaseHardwareInputs(profile.bindings(), board.info(), pressed,
        [](const HardwareBinding& binding, const NativeAction& action) { return dispatch(binding, action); });
    board.inputs()->release();
}
bool touchControl(size_t index, const char* event, double value) {
    if (!std::strcmp(event, "release")) { cancelJog(); return true; }
    JsonObject tile = profile.json["pages"][profile.pageIndex()]["controls"][index];
    if (tile.isNull()) return false;
    HardwareBinding binding;
    if (!parseAction(tile["action"], binding.action)) return false;
    strlcpy(binding.inputID, "touch", sizeof(binding.inputID));
    strlcpy(binding.pageID, profile.bindings().activePageID, sizeof(binding.pageID));
    strlcpy(binding.controlID, tile["id"] | "", sizeof(binding.controlID));
    const bool slider = !std::strcmp(tile["kind"] | "", "slider");
    const bool jog = !std::strcmp(binding.action.type, "openBuilds") && !std::strncmp(binding.action.text, "continuousJog", 13);
    if (slider) {
        binding.state = tileSliderState(binding.action);
        if (!std::isfinite(value)) return false;
        const double bounded = boundValue(value, binding.state);
        binding.action.value = int32_t(std::round(mediaWireValue(binding.action, bounded)));
        binding.action.valueTenths = int32_t(std::round(bounded * 10));
    } else if ((!jog && std::strcmp(event, "activate")) || (jog && std::strcmp(event, "press"))) return false;
    if (jog) {
        cancelJog();
        touchJog.reset(new (std::nothrow) HardwareBinding(binding));
        if (!touchJog) return false;
    }
    const bool sent = dispatch(binding, binding.action);
    if (jog && !sent) touchJog.reset();
    if (sent) updateTile(binding, binding.action);
    return sent;
}
void changePage(int delta) {
    if (profile.json["pages"].size() < 2) return;
    releaseInputs();
    profile.changePage(delta);
}
void input(const InputEvent& event) {
    if (!std::strcmp(event.event, "overflow")) { releaseInputs(); return; }
    const bool waking = saverActive;
    displayActivity();
    if (!std::strcmp(wakeButton, event.inputID)) {
        if (!std::strcmp(event.event, "release")) wakeButton[0] = 0;
        return;
    }
    if (waking) {
        if (!std::strcmp(event.event, "press") || !std::strcmp(event.event, "hold"))
            strlcpy(wakeButton, event.inputID, sizeof(wakeButton));
        return;
    }
    for (size_t index = 0; index < board.info().inputCount; ++index) {
        if (std::strcmp(board.info().inputs[index].id, event.inputID)) continue;
        if (!std::strcmp(event.event, "press")) pressed[index] = true;
        else if (!std::strcmp(event.event, "release")) pressed[index] = false;
    }
    if (event.relative && !std::strcmp(event.inputID, "dial-1") && waveshareUiSliderHeld()) return;
    if (profile.ready() && event.relative && !std::strcmp(event.inputID, "dial-1")) {
        const uint32_t now = hardware::millisNow();
        for (size_t index = 0; index < profile.bindings().count; ++index) {
            auto& binding = profile.bindings().bindings[index];
            if (!binding.controlID[0] || binding.state.mode == BindingMode::action ||
                std::strcmp(binding.inputID, event.inputID) || std::strcmp(binding.event, event.event) ||
                !bindingOnActivePage(profile.bindings(), binding) || std::strcmp(binding.action.text, "seek")) continue;
            const auto* media = mediaState(binding.action);
            if (media) rebaseSeekBinding(binding, *media, now);
        }
    }
    if (profile.ready()) dispatchHardwareInput(profile.bindings(), board.info(), event,
        [](const HardwareBinding& binding, const NativeAction& action) {
            const bool safety = !std::strcmp(action.type, "openBuilds") && !std::strcmp(action.text, "cancelJog");
            const bool sent = dispatch(binding, action, safety);
            if (sent) updateTile(binding, action);
            return sent;
        });
}
std::string dialJSON(const DialConfiguration& settings) {
    JsonDocument json;
    json["mode"] = int(settings.mode);
    json["start"] = settings.start;
    json["sweep"] = settings.sweep;
    json["turns"] = settings.turns;
    json["step"] = settings.step;
    json["jitter"] = settings.jitter;
    json["lowLatency"] = settings.lowLatency;
    json["rate"] = settings.rate;
    std::string result;
    serializeJson(json, result);
    return result;
}
void loadDial() {
    if (nvs_open("papergif-dial", NVS_READWRITE, &dialStorage) != ESP_OK) return;
    size_t length = 0;
    if (nvs_get_str(dialStorage, "settings", nullptr, &length) != ESP_OK || !length || length > 2048) return;
    std::string stored(length, '\0');
    if (nvs_get_str(dialStorage, "settings", stored.data(), &length) != ESP_OK) return;
    JsonDocument json;
    if (deserializeJson(json, stored.c_str())) return;
    const int mode = json["mode"] | -1;
    if (mode < 0 || mode > 2) return;
    for (const char* field : {"start", "sweep", "turns", "step", "jitter"}) if (!json[field].is<double>()) return;
    auto clean = [](double value) { return std::round(value * 1e6) / 1e6; };
    DialConfiguration settings;
    settings.mode = static_cast<DialMode>(mode);
    settings.start = clean(json["start"]);
    settings.sweep = clean(json["sweep"]);
    settings.turns = clean(json["turns"]);
    settings.step = clean(json["step"]);
    settings.jitter = clean(json["jitter"]);
    settings.lowLatency = json["lowLatency"] | false;
    settings.rate = clean(json["rate"] | dial_stream::defaultRate);
    if (json["reversed"] | false) { settings.sweep = -settings.sweep; settings.turns = -settings.turns; }
    if (!board.configureDial(settings)) ESP_LOGW("dial", "Saved dial configuration is invalid");
}
bool readControl(const device_controls::Control& item, device_controls::Value& value) {
    using namespace reference_controls;
    const auto& dial = board.dialTracker();
    const auto& settings = dial.configuration();
    switch (&item - controls) {
    case screensaverEnabled: value.boolean = saverEnabled; return true;
    case screensaverDelay: value.number = saverDelay; return true;
    case screensaverInterval: value.number = saverInterval; return true;
    case screensaverImageCount: value.number = images.count(); return true;
    case sdCardMounted: value.boolean = mediaCard != nullptr; return true;
    case mediaImageLimit: value.number = images.capacity(); return true;
    case sdCardCapacity: if (!mediaCard) return false;
        value.number = double(mediaCard->csd.capacity) * mediaCard->csd.sector_size / (1024 * 1024); return true;
    case wifiConnected: value.boolean = connected(); return true;
    case wifiSignal: if (!connected()) return false; value.number = signal(); return true;
    case dialPresent: value.boolean = board.dialPresent(); return true;
    case dialPosition: if (!dial.ready()) return false; value.number = std::round(dial.positionDegrees() * 100) / 100; return true;
    case dialAngle: if (!dial.ready()) return false; value.number = std::round(dial.shaftAngle() * 100) / 100; return true;
    case dialOutput: if (!dial.ready()) return false; value.number = dial.outputPercent(); return true;
    case dialMode: value.text = dialModes[int(settings.mode)].value; return true;
    case dialStart: value.number = settings.start; return true;
    case dialSweep: value.number = settings.sweep; return true;
    case dialTurns: value.number = settings.turns; return true;
    case dialStep: value.number = settings.step; return true;
    case dialJitter: value.number = settings.jitter; return true;
    case dialLowLatency: value.boolean = settings.lowLatency; return true;
    case dialRate: value.number = settings.rate; return true;
    default: return false;
    }
}
std::string controlsJSON(bool ok = false) {
    JsonDocument json;
    if (ok) json["ok"] = true;
    device_controls::writeSnapshot(json["values"].to<JsonObject>(), reference_controls::controls, reference_controls::count, readControl);
    std::string result;
    serializeJson(json, result);
    return result;
}
device_controls::Status applyControl(const device_controls::Control& item, const device_controls::Value& value) {
    using namespace reference_controls;
    using device_controls::Status;
    if (profile.busy() || images.busy() || restartPending) return Status::busy;
    const auto index = &item - controls;
    if (index == restart) { restartPending = true; restartAt = hardware::millisNow() + 300; return Status::ok; }
    if (index >= screensaverEnabled && index <= screensaverClear) {
        if (index == screensaverNow) {
            if (!images.count()) return Status::invalidValue;
            releaseInputs();
            saverActive = true;
            saverOffset = 0;
            saverStartedAt = hardware::millisNow();
        } else if (index == screensaverClear) {
            images.clearScreens();
            displayActivity();
        } else {
            const char* key = index == screensaverEnabled ? "enabled" : index == screensaverDelay ? "delay" : "interval";
            const uint32_t setting = index == screensaverEnabled ? uint32_t(value.boolean) : uint32_t(value.number);
            if (!imageStorage || nvs_set_u32(imageStorage, key, setting) != ESP_OK || nvs_commit(imageStorage) != ESP_OK)
                return Status::busy;
            if (index == screensaverEnabled) saverEnabled = setting;
            else if (index == screensaverDelay) saverDelay = setting;
            else saverInterval = setting;
            displayActivity();
        }
        return Status::ok;
    }
    if (index < dialMode || index > dialZero) return Status::readOnly;
    auto settings = board.dialTracker().configuration();
    switch (index) {
    case dialMode:
        for (int mode = 0; mode < 3; ++mode) if (!std::strcmp(value.text, dialModes[mode].value)) settings.mode = static_cast<DialMode>(mode);
        break;
    case dialStart: settings.start = value.number; break;
    case dialSweep: settings.sweep = value.number; break;
    case dialTurns: settings.turns = value.number; break;
    case dialStep: settings.step = value.number; break;
    case dialJitter: settings.jitter = value.number; break;
    case dialLowLatency: settings.lowLatency = value.boolean; break;
    case dialRate: settings.rate = value.number; break;
    case dialZero:
        if (!board.dialPresent()) return Status::busy;
        settings.start = std::min(359.9, board.dialTracker().shaftAngle());
        break;
    }
    if (!settings.valid()) return Status::invalidValue;
    const auto saved = dialJSON(settings);
    if (!dialStorage || nvs_set_str(dialStorage, "settings", saved.c_str()) != ESP_OK || nvs_commit(dialStorage) != ESP_OK) return Status::busy;
    board.configureDial(settings);
    if (index == dialZero) board.zeroDial();
    return Status::ok;
}
void snapshot(uint16_t requester, bool broadcast) {
    const auto json = controlsJSON();
    const uint8_t header[] = {device_controls::snapshotFragment};
    if (requester != noConnection) fragments(requester, header, sizeof(header), json);
    if (broadcast) {
        for (size_t index = 0; index < subscribers.size(); ++index)
            if (subscribers.at(index) != requester) fragments(subscribers.at(index), header, sizeof(header), json);
        lastSnapshot = json;
    }
}
void registerRelay(const BLEFrame& frame) {
    std::string response;
    response.push_back(char(device_controls::relayRegistered));
    response.push_back(1);
    if (profile.ready() && frame.length >= 3 && frame.bytes[1] <= 1) {
        const auto computers = profile.json["computers"].as<JsonArrayConst>();
        const int index = device_controls::tokenComputerIndex(reinterpret_cast<const char*>(frame.bytes + 2), frame.length - 2,
            profile.json["macToken"] | "", computers.size(), [&computers](size_t position) { return computers[position]["token"] | ""; });
        if (index != -2 && relays.add(frame.connection, index, static_cast<device_controls::RelayRole>(frame.bytes[1]))) {
            response[1] = 0;
            if (index >= 0) response += computers[index]["id"] | "";
        }
    }
    packet(frame.connection, reinterpret_cast<const uint8_t*>(response.data()), response.size());
}
void consume(const BLEFrame& frame) {
    const auto imageCount = images.count();
    if (images.consume(frame, profile.busy())) {
        displayActivity();
        if (images.count() > imageCount) {
            releaseInputs();
            saverActive = true;
            saverOffset = images.count() - 1;
            saverStartedAt = hardware::millisNow();
        }
        return;
    }
    const int activeImage = saverActive && imageCount
        ? int((saverOffset + (hardware::millisNow() - saverStartedAt) / (saverInterval * 1000)) % imageCount) : -1;
    if (images.library(frame, activeImage)) {
        if (images.count() != imageCount) displayActivity();
        return;
    }
    if (frame.kind == FrameKind::control && frame.length && frame.bytes[0] == 0x25) {
        if (frame.length == 2 && frame.bytes[1] < images.count() && !images.busy()) {
            releaseInputs();
            saverOffset = frame.bytes[1];
            saverStartedAt = hardware::millisNow();
            saverActive = true;
        } else {
            const uint8_t error = 0x7f;
            notify(frame.connection, &error, 1);
        }
        return;
    }
    if (images.busy() && frame.kind == FrameKind::control && frame.length && frame.bytes[0] == 0x40) {
        const uint8_t error = 0x7f;
        notify(frame.connection, &error, 1);
        return;
    }
    if (frame.kind == FrameKind::disconnected) {
        const bool relayOnly = relays.isRelay(frame.connection) && !subscribers.contains(frame.connection) && phone != frame.connection;
        relays.removeHandle(frame.connection);
        subscribers.remove(frame.connection);
        relaySequences.removeHandle(frame.connection);
        if (phone == frame.connection) { phone = noConnection; phoneMedia = {}; }
        if (!relayOnly) releaseInputs();
        profile.consume(frame);
        return;
    }
    if (profile.consume(frame) || consumeWiFi(frame, !profile.ready() || relays.isRelay(frame.connection))) return;
    if (frame.kind != FrameKind::control || !frame.length) return;
    const auto* bytes = frame.bytes;
    switch (bytes[0]) {
    case 0x62:
        if (frame.length == 1) {
            if (phone != frame.connection) phoneMedia = {};
            phone = frame.connection;
        }
        break;
    case 0x61:
        if (phone == frame.connection) phoneMedia.updatePhone(bytes, frame.length, hardware::millisNow());
        break;
    case 0x63: break;
    case device_controls::snapshotRequest:
        if (frame.length == 1) { subscribers.add(frame.connection); snapshot(frame.connection, false); }
        break;
    case device_controls::setRequest: {
        const device_controls::Control* item = nullptr;
        device_controls::Value value;
        auto status = device_controls::parseSetRequest(reinterpret_cast<const char*>(bytes + 1), frame.length - 1,
            reference_controls::controls, reference_controls::count, item, value);
        if (status == device_controls::Status::ok) status = applyControl(*item, value);
        const uint8_t response[] = {device_controls::setResult, uint8_t(status)};
        packet(frame.connection, response, sizeof(response));
        if (status == device_controls::Status::ok) snapshot(frame.connection, true);
        break;
    }
    case device_controls::relayRegister: registerRelay(frame); break;
    case device_controls::relayResult:
        if (frame.length == 3 && relaySequences.complete(frame.connection, bytes[1]) && bytes[2])
            ESP_LOGW("relay", "Action failed: %u", bytes[2]);
        break;
    default: break;
    }
}
void http(HTTPRequest& request) {
    JsonDocument json;
    if (request.path == "/status" && !request.post) {
        json["device"] = "paperGIF";
        json["ready"] = storageReady;
        json["uploading"] = profile.busy();
        json["firmware"] = PAPERGIF_FIRMWARE_VERSION;
    } else if (!profile.authorized(request.token)) {
        request.status = 401; json["error"] = "unauthorized";
    } else if (request.path == "/images") {
        char normalized[37]{};
        const bool valid = remote_button_texture::normalizeImageId(request.imageID.c_str(), normalized) &&
            (request.imageKind == "screen" || request.imageKind == "button") &&
            (request.remove || (request.imageCRC.size() == 8 &&
                std::strspn(request.imageCRC.c_str(), "0123456789abcdefABCDEF") == 8));
        if (!valid) { request.status = 400; json["error"] = "invalid_image_headers"; }
        else if (profile.busy() || images.busy()) { request.status = 409; json["error"] = "busy"; }
        else if (request.authorizationOnly) { json["ok"] = true; }
        else {
            const bool button = request.imageKind == "button";
            size_t index = SIZE_MAX;
            const size_t previous = images.count();
            request.status = request.remove ? images.removeHTTP(normalized, button) : images.uploadHTTP(
                reinterpret_cast<const uint8_t*>(request.body.data()), request.body.size(), normalized,
                request.imageName.c_str(), uint32_t(std::strtoul(request.imageCRC.c_str(), nullptr, 16)), button, index);
            if (request.status == 200 || request.status == 201) {
                json["ok"] = true;
                json["id"] = normalized;
                if (!button && !request.remove) json["index"] = index;
                displayActivity();
                if (!button && !request.remove && images.count() > previous) {
                    releaseInputs();
                    saverActive = true;
                    saverOffset = index;
                    saverStartedAt = hardware::millisNow();
                }
            } else {
                json["error"] = request.status == 400 ? "invalid_image" : request.status == 409 ? "image_conflict" :
                    request.status == 507 ? "storage_full" : request.status == 404 ? "not_found" : "image_storage_failed";
            }
        }
    } else if (request.path == "/text-source/update" && request.post) {
        JsonDocument response;
        if (deserializeJson(response, request.body) || !response["items"].is<JsonArray>()) {
            request.status = 400; json["error"] = "invalid_media_state";
        } else {
            for (int index = -1; index < 8; ++index) {
                if (request.token == computerToken(index))
                    applyMediaItems(response.as<JsonVariantConst>(), index, hardware::millisNow());
            }
            json["ok"] = true;
        }
    } else if (request.path == "/remote") {
        if (!request.post) { request.response = profile.payload(); return; }
        if (profile.busy() || images.busy()) { request.status = 409; json["error"] = "busy"; }
        else if (!storageReady) { request.status = 503; json["error"] = "storage_unavailable"; }
        else if (profile.install(request.body, true)) { request.status = 201; json["ok"] = true; }
        else { request.status = 400; json["error"] = profile.problem(); }
    } else if (request.path == "/device/controls") {
        if (!request.post) { request.response = controlsJSON(); return; }
        const device_controls::Control* item = nullptr;
        device_controls::Value value;
        auto status = device_controls::parseSetRequest(request.body.data(), request.body.size(),
            reference_controls::controls, reference_controls::count, item, value);
        if (status == device_controls::Status::ok) status = applyControl(*item, value);
        if (status == device_controls::Status::ok) { request.response = controlsJSON(true); snapshot(noConnection, true); return; }
        request.status = device_controls::httpStatus(status);
        device_controls::writeError(json, device_controls::errorName(status));
    } else if (request.path == "/debug/inputs") {
        uint16_t angle = 0;
        json["boardID"] = board.info().id;
        json["pageIndex"] = profile.pageIndex();
        json["screensaverImages"] = images.count();
        json["screensaverActive"] = saverActive;
        json["resetReason"] = int(esp_reset_reason());
        imageHTTPDiagnostics(json["imageHTTP"].to<JsonObject>());
        board.displayDiagnostics(json["display"].to<JsonObject>());
        auto media = json["media"].to<JsonArray>();
        for (int index = -1; index < 9; ++index) {
            const auto& state = index == 8 ? phoneMedia : computerMedia[index + 1].state;
            auto item = media.add<JsonObject>();
            item["source"] = index == 8 ? "iPhone" : "computer";
            item["computerIndex"] = index;
            item["available"] = state.timeline.available;
            item["playing"] = state.timeline.playing;
            item["stale"] = state.timeline.stale;
            item["elapsedMilliseconds"] = media_timeline::elapsedAt(state.timeline, hardware::millisNow());
            item["durationMilliseconds"] = state.timeline.durationMilliseconds;
            item["text"] = state.text;
        }
        json["button1Pressed"] = board.buttonPressedForDiagnostics(0);
        json["button2Pressed"] = board.buttonPressedForDiagnostics(1);
        json["mt6701Present"] = board.readDialForDiagnostics(angle);
        json["angle"] = angle;
        json["droppedInputEvents"] = board.droppedInputEvents();
        json["inputSampleCount"] = board.inputSampleCount();
        json["inputStackFreeBytes"] = board.inputStackFreeBytes();
        if (hasLastInput) {
            json["lastInputID"] = lastInput.inputID;
            json["lastEvent"] = lastInput.event;
            json["lastValue"] = lastInput.value;
            json["lastSequence"] = lastInput.sequence;
        }
    } else { request.status = 404; json["error"] = "not_found"; }
    serializeJson(json, request.response);
}
void pollControls() {
    ActionRequest* retry = nullptr;
    while (takeRelayRetry(retry)) {
        if (retry->profileRevision == profile.generation()) relayAction(retry->relayComputer, true, retry->body);
        delete retry;
    }
    if (restartPending && int32_t(hardware::millisNow() - restartAt) >= 0) { releaseInputs(); esp_restart(); }
    if (hardware::millisNow() - snapshotAt >= 200) {
        snapshotAt = hardware::millisNow();
        if (subscribers.size() && controlsJSON() != lastSnapshot) snapshot(noConnection, true);
    }
    const auto settings = board.dialTracker().configuration();
    const double rate = settings.lowLatency ? settings.rate : dial_stream::maximumRate;
    pollStream(rate);
    livePacer.setRate(rate);
    phonePacer.setRate(rate);
    const uint32_t now = hardware::microsNow();
    if (livePacer.poll(now) != dial_stream::Pacer::Send::none) {
        uint8_t bytes[7];
        const size_t length = dial_stream::encodeLiveDial(bytes, board.dialTracker().shaftAngle(), board.dialTracker().positionDegrees());
        for (size_t index = 0; index < subscribers.size(); ++index) notify(subscribers.at(index), bytes, length);
    }
    if (phonePacer.poll(now) != dial_stream::Pacer::Send::none && phone != noConnection) notify(phone, phonePacket, sizeof(phonePacket));
}
void refreshRelays() {
    std::string keys = profile.json["macToken"] | "";
    for (JsonObjectConst computer : profile.json["computers"].as<JsonArrayConst>()) {
        keys += '\0'; keys += computer["id"] | "";
        keys += '\0'; keys += computer["token"] | "";
    }
    if (keys != relayProfileKeys) { relays = {}; relaySequences = {}; }
    relayProfileKeys = std::move(keys);
}
}

extern "C" void app_main() {
    esp_log_level_set("NimBLE", ESP_LOG_WARN);
    ESP_ERROR_CHECK(nvs_flash_init());
    ESP_LOGI("paperremote", "Native ESP-IDF %s", esp_get_idf_version());
    ESP_LOGI("paperremote", "%s", waveshareAmoled18FirmwareIdentity);
    board.begin();
    loadDial();
    storageReady = profile.begin();
    const bool cardReady = mountMediaCard();
    images.begin(cardReady || storageReady, cardReady ? "/sdcard/paperGIF" : "/profiles", cardReady ? 128 : 4);
    if (nvs_open("papergif-media", NVS_READWRITE, &imageStorage) == ESP_OK) {
        uint32_t enabled = 1;
        nvs_get_u32(imageStorage, "enabled", &enabled);
        saverEnabled = enabled != 0;
        nvs_get_u32(imageStorage, "delay", &saverDelay);
        nvs_get_u32(imageStorage, "interval", &saverInterval);
        saverDelay = std::clamp(saverDelay, uint32_t(10), uint32_t(3600));
        saverInterval = std::clamp(saverInterval, uint32_t(5), uint32_t(300));
    }
    displayActivity();
    refreshRelays();
    uint8_t mac[6];
    ESP_ERROR_CHECK(esp_read_mac(mac, ESP_MAC_WIFI_STA));
    uint64_t identifier = 0;
    for (size_t index = 0; index < sizeof(mac); ++index) identifier |= uint64_t(mac[index]) << (8 * index);
    char deviceID[24], hostname[24];
    std::snprintf(deviceID, sizeof(deviceID), "papergif-%012llx", static_cast<unsigned long long>(identifier));
    std::snprintf(hostname, sizeof(hostname), "op-remote-%04x", unsigned(identifier & 0xffff));
    JsonDocument descriptor;
    writeDeviceDescriptor(descriptor, board.info(), deviceID, PAPERGIF_FIRMWARE_VERSION,
        reference_controls::controls, reference_controls::count);
    descriptor["capabilities"]["media"] = true;
    auto imageFormats = descriptor["capabilities"]["imageFormats"].to<JsonArray>();
    imageFormats.add("pimg-rgb565-v1");
    imageFormats.add("pbgi-gray8-v1");
    imageFormats.add("pbgi-rgb565-v2");
    auto imageTransports = descriptor["capabilities"]["imageTransports"].to<JsonArray>();
    imageTransports.add("http");
    imageTransports.add("ble");
    descriptor["capabilities"]["mediaStorageID"] = std::to_string(esp_random()) + "-" + std::to_string(esp_random());
    std::string encoded;
    serializeJson(descriptor, encoded);
    beginNetwork(hostname, encoded, board.info().maxProfileBytes);
    configureNetwork(profile.json, false);
    if (!beginBluetooth(encoded)) ESP_LOGE("paperremote", "Bluetooth initialization failed");
    profile.beforeInstall = releaseInputs;
    profile.afterInstall = [] {
        for (auto& source : computerMedia) source = {};
        refreshRelays();
        configureNetwork(profile.json, true);
    };
    ESP_LOGI("paperremote", "Ready: %u internal bytes, %u PSRAM bytes", unsigned(heap_caps_get_free_size(MALLOC_CAP_INTERNAL)),
        unsigned(heap_caps_get_free_size(MALLOC_CAP_SPIRAM)));
    WaveshareUiState ui;
    ui.controlEvent = touchControl;
    ui.changePage = changePage;
    ui.mediaState = mediaState;
    ui.activity = displayActivity;
    ui.buttonImage = [](const char* id) { return images.buttonImage(id); };
    for (;;) {
        static bool gestureDialSuppressed = false;
        if (waveshareUiGestureActive()) {
            gestureDialSuppressed = true;
            board.discardGestureDial();
            ui.now = hardware::millisNow();
            ui.pageIndex = profile.pageIndex();
            ui.profileRevision = profile.generation();
            waveshareUiPoll(ui);
            BLEFrame frame;
            for (int count = 0; count < 2 && readBluetooth(frame); ++count) consume(frame);
            pollBluetooth();
            hardware::wait(0);
            continue;
        }
        if (gestureDialSuppressed) {
            gestureDialSuppressed = false;
            board.discardGestureDial();
        }
        if (pollNetwork()) releaseInputs();
        BLEFrame frame;
        for (int count = 0; count < 32 && readBluetooth(frame); ++count) consume(frame);
        HTTPRequest* request = nullptr;
        if (takeHTTP(request)) {
            if (!request->abandoned) http(*request);
            completeHTTP(request);
        }
        board.setRelativeDialOutput(profile.ready() && hasSliderDialBinding(profile.bindings()));
        InputEvent event;
        for (int count = 0; count < 8 && board.inputs()->poll(event); ++count) {
            lastInput = event;
            hasLastInput = true;
            if (!std::strcmp(event.inputID, "dial-1") && board.dialTracker().configuration().lowLatency) livePacer.offer();
            input(event);
        }
        pollControls();
        flushRelay(false);
        pollMedia();
        ui.configured = profile.ready();
        ui.profile = &profile.json;
        ui.pageIndex = profile.pageIndex();
        ui.profileRevision = profile.generation();
        ui.now = hardware::millisNow();
        images.poll(ui.now);
        if (!saverActive && saverEnabled && images.count() && !images.busy() && !profile.busy() &&
            !touchJog && std::none_of(std::begin(pressed), std::end(pressed), [](bool value) { return value; }) &&
            ui.now - lastActivity >= saverDelay * 1000) {
            releaseInputs();
            saverActive = true;
            saverOffset = 0;
            saverStartedAt = ui.now;
        }
        ui.screensaver = saverActive;
        ui.screenImage = saverActive ? images.screen(saverOffset + (ui.now - saverStartedAt) / (saverInterval * 1000)) : nullptr;
        ui.imageRevision = images.generation();
        waveshareUiPoll(ui);
        pollBluetooth();
        profile.poll(hardware::millisNow());
        hardware::wait(1);
    }
}