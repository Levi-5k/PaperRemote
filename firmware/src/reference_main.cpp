#include <Arduino.h>
#include <ArduinoJson.h>
#include <ESPmDNS.h>
#include <HTTPClient.h>
#include <LittleFS.h>
#include <NimBLEDevice.h>
#include <WebServer.h>
#include <WiFi.h>
#include <WiFiUdp.h>
#include <Preferences.h>
#include "device_descriptor.h"
#include "firmware_identity.h"
#include "local_http_policy.h"
#include "reference_controls.h"
#include "reference_inputs.h"
#include "supermini_s3_board.h"
#include "reference_profile.h"
#include "remote_action_payload.h"
#include "remote_computer.h"
#include "remote_network_queue.h"
#include "reference_lifecycle.h"
#include "wifi_setup.h"
#include "dial_stream.h"

#ifndef PAPERGIF_FIRMWARE_VERSION
#define PAPERGIF_FIRMWARE_VERSION "0.0.0"
#endif
#ifndef PAPERGIF_REFERENCE_FORMAT_ON_MOUNT_FAILURE
#define PAPERGIF_REFERENCE_FORMAT_ON_MOUNT_FAILURE 0
#endif

namespace {
using namespace paper_board;
constexpr char serviceUuid[] = "7A230001-7D2A-4C7B-9C42-504749460001";
constexpr char controlUuid[] = "7A230002-7D2A-4C7B-9C42-504749460001";
constexpr char dataUuid[] = "7A230003-7D2A-4C7B-9C42-504749460001";
#if defined(PAPERGIF_SUPERMINI_S3)
SuperMiniS3Board board;
constexpr const char* deviceFirmwareIdentity = superminiS3FirmwareIdentity;
constexpr const char* bluetoothDeviceName = "paperGIF SuperMini S3";
#else
ReferenceBoard board;
constexpr const char* deviceFirmwareIdentity = referenceFirmwareIdentity;
constexpr const char* bluetoothDeviceName = "paperGIF Reference";
#endif
WebServer server(80);
String deviceJSON;
DescriptorCallbacks descriptorCallbacks(deviceJSON);
JsonDocument profileJSON;
NativeProfile profile;
bool configured = false;
const char* profileError = "invalid_profile";
bool storageReady = false;
bool pressed[3]{};
volatile bool disconnected = false;
#if defined(PAPERGIF_SUPERMINI_S3)
InputEvent lastSuperminiInput{"", "", 0, 0};
bool hasLastSuperminiInput = false;
#endif
NimBLECharacteristic* control = nullptr;
uint16_t iPhoneController = UINT16_MAX;
SemaphoreHandle_t networkMutex = nullptr;
struct Request {
    char url[256]{}, body[1024]{}, token[80]{}, method[5] = "POST", controlId[32]{};
    bool slider = false;
    uint32_t profileRevision = 0;
    int8_t relayComputer = -3;  // Computer index for a Bluetooth relay retry; -3 = none.
};
remote_network::WorkQueue<Request, 16> networkQueue;
uint32_t profileRevision = 0;
bool stationConnectPending = false;
constexpr int noRelayComputer = -3;
constexpr uint32_t restartDelayMs = 300;
constexpr uint32_t snapshotCheckMs = 2000;
#ifndef PAPERGIF_WIFI_TX_POWER
#define PAPERGIF_WIFI_TX_POWER WIFI_POWER_8_5dBm
#endif
// Wi-Fi joined from the phone's network picker; takes precedence over the profile's wifiSSID.
Preferences wifiPreferences;
bool wifiStorageReady = false;
wifi_setup::Credentials setupCredentials;
wifi_setup::JoinTracker wifiJoin;
volatile uint16_t lastDisconnectReason = 0;
uint16_t wifiScanRequester = UINT16_MAX;
bool wifiScanResume = false;
constexpr size_t maxScanNetworks = 20;
struct ScannedNetwork { char ssid[wifi_setup::maxSSID + 1]; int8_t rssi; bool secure; };
ScannedNetwork scannedNetworks[maxScanNetworks];
size_t scannedNetworkCount = 0;
#if defined(PAPERGIF_SUPERMINI_S3)
constexpr uint32_t dialSnapshotCheckMs = 100;
Preferences dialPreferences;
bool dialStorageReady = false;

String dialConfigurationJSON(const DialConfiguration& settings) {
    JsonDocument json;
    json["mode"] = int(settings.mode);
    json["start"] = settings.start;
    json["sweep"] = settings.sweep;
    json["turns"] = settings.turns;
    json["step"] = settings.step;
    json["jitter"] = settings.jitter;
    json["lowLatency"] = settings.lowLatency;
    json["rate"] = settings.rate;
    String result;
    serializeJson(json, result);
    return result;
}
void loadDialConfiguration() {
    dialStorageReady = dialPreferences.begin("papergif-dial", false);
    if (!dialStorageReady) { Serial.println("Dial settings storage unavailable"); return; }
    const String stored = dialPreferences.getString("settings", "");
    if (stored.isEmpty()) return;
    JsonDocument json;
    if (deserializeJson(json, stored)) { Serial.println("Invalid saved dial settings JSON"); return; }
    DialConfiguration candidate;
    const int mode = json["mode"] | -1;
    if (mode < 0 || mode > 2 || !json["start"].is<double>() ||
        !json["sweep"].is<double>() || !json["turns"].is<double>() ||
        !json["step"].is<double>() || !json["jitter"].is<double>()) {
        Serial.println("Invalid saved dial settings fields");
        return;
    }
    // Saved numbers can come back as 32-bit floats (0.01 -> 0.0099999998); drop
    // that noise so values saved at a limit still pass validation.
    auto clean = [](double value) { return std::round(value * 1e6) / 1e6; };
    candidate.mode = static_cast<DialMode>(mode);
    candidate.start = clean(json["start"]);
    candidate.sweep = clean(json["sweep"]);
    candidate.turns = clean(json["turns"]);
    candidate.step = clean(json["step"]);
    candidate.jitter = clean(json["jitter"]);
    // Fields added later default when absent from older saved settings.
    candidate.lowLatency = json["lowLatency"] | false;
    candidate.rate = clean(json["rate"] | dial_stream::defaultRate);
    // Older firmware stored a separate reverse flag; fold it into the end stop side.
    if (json["reversed"] | false) {
        candidate.sweep = -candidate.sweep;
        candidate.turns = -candidate.turns;
    }
    if (!board.configureDial(candidate)) Serial.println("Invalid saved dial settings range");
}
#endif
// Relay and snapshot state is touched by NimBLE callbacks and the loop task.
portMUX_TYPE deviceControlLock = portMUX_INITIALIZER_UNLOCKED;
device_controls::RelayRegistry relays;
device_controls::HandleSet snapshotSubscribers;
device_controls::RelaySequences relaySequences;
String lastSnapshot;
uint32_t snapshotCheckedAt = 0;
bool restartPending = false;
uint32_t restartAt = 0;
struct RelayRetry {
    int8_t computer;
    char body[sizeof(Request::body)];
};
QueueHandle_t relayRetries = nullptr;

uint16_t relayHandleFor(int computer, bool directOnly) {
    portENTER_CRITICAL(&deviceControlLock);
    const uint16_t handle = relays.find(computer, directOnly);
    portEXIT_CRITICAL(&deviceControlLock);
    return handle;
}
bool notifyPacket(uint16_t handle, const uint8_t* data, size_t length) {
    if (!control) return false;
    for (int attempt = 0; attempt < 10; ++attempt) {
        if (control->notify(data, length, handle)) return true;
        delay(5);
    }
    return false;
}
bool sendFragmented(uint16_t handle, const uint8_t* header, size_t headerLength, const String& data) {
    const uint16_t mtu = NimBLEDevice::getServer() ? NimBLEDevice::getServer()->getPeerMTU(handle) : 23;
    return device_controls::sendFragments(header, headerLength, data.c_str(), data.length(),
        device_controls::packetLimit(mtu),
        [handle](const uint8_t* packet, size_t length) { return notifyPacket(handle, packet, length); }) > 0;
}
// Computer index used by the relay registry: profile computers by position, -1 for legacy.
int computerIndexFor(const NativeAction& action) {
    JsonArrayConst computers = profileJSON["computers"].as<JsonArrayConst>();
    if (computers.size() == 0) return action.computerId[0] ? -2 : -1;
    int index = 0;
    for (JsonObjectConst computer : computers) {
        if (!action.computerId[0] || remote_computer::sameId(action.computerId, computer["id"] | ""))
            return index;
        ++index;
    }
    return -2;
}
bool sendRelayAction(int computer, bool directOnly, const char* body) {
    const uint16_t handle = relayHandleFor(computer, directOnly);
    if (handle == device_controls::RelayRegistry::none || !control) return false;
    const char* computerId = computer >= 0 ? (profileJSON["computers"][computer]["id"] | "") : "";
    JsonDocument frame;
    frame["computerId"] = computerId;
    frame["body"] = serialized(body);
    String json;
    serializeJson(frame, json);
    portENTER_CRITICAL(&deviceControlLock);
    const uint8_t sequence = relaySequences.next(handle);
    portEXIT_CRITICAL(&deviceControlLock);
    const uint8_t header[] = {device_controls::relayAction, sequence};
    const bool sent = sendFragmented(handle, header, sizeof(header), json);
    Serial.printf("BLE relay action seq=%u computer=%d -> %s\n", sequence, computer, sent ? "sent" : "failed");
    return sent;
}

// Dial/slider values relayed over Bluetooth are coalesced: only the newest value is
// sent, at most every relaySliderIntervalMs, so a fast-turning knob cannot flood the link.
constexpr uint32_t relaySliderIntervalMs = 40;
struct PendingRelaySlider {
    bool active = false;
    int computer = 0;
    char controlId[sizeof(Request::controlId)] = "";
    String body;
} pendingRelaySlider;
uint32_t relaySliderSentAt = 0;
void flushRelaySlider(bool force) {
    if (!pendingRelaySlider.active) return;
    if (!force && millis() - relaySliderSentAt < relaySliderIntervalMs) return;
    pendingRelaySlider.active = false;
    relaySliderSentAt = millis();
    sendRelayAction(pendingRelaySlider.computer, false, pendingRelaySlider.body.c_str());
}

bool localAuthority(const char* raw, String& authority) {
    authority = raw;
    if (authority.startsWith("http://")) authority.remove(0, 7);
    while (authority.endsWith("/")) authority.remove(authority.length() - 1);
    if (!authority.length() || authority.indexOf('/') >= 0 || authority.indexOf('@') >= 0 ||
        authority.indexOf('?') >= 0 || authority.indexOf('#') >= 0 ||
        authority.indexOf('\r') >= 0 || authority.indexOf('\n') >= 0) return false;
    String host = authority;
    const int colon = host.indexOf(':');
    if (colon >= 0) {
        const String port = host.substring(colon + 1);
        if (!port.length() || port.length() > 5) return false;
        for (size_t i = 0; i < port.length(); ++i) if (!isDigit(port[i])) return false;
        if (port.toInt() < 1 || port.toInt() > 65535) return false;
        host = host.substring(0, colon);
    }
    IPAddress address;
    return (address.fromString(host) && local_http::isPrivateIPv4(address[0], address[1])) ||
        local_http::isLocalHostname(host.c_str());
}
JsonObjectConst targetComputer(const NativeAction& action) {
    for (JsonObjectConst computer : profileJSON["computers"].as<JsonArrayConst>()) {
        if (!action.computerId[0] ||
            remote_computer::sameId(action.computerId, computer["id"] | "")) return computer;
    }
    return JsonObjectConst{};
}
#if defined(PAPERGIF_SUPERMINI_S3)
// Low latency dial stream: change-only values, paced to the configured rate. Computers get
// UDP datagrams on their action port; the phone gets compact Bluetooth notifications.
struct DialStreamTarget {
    IPAddress address;
    uint16_t port = 0;
    String token, body;
};
WiFiUDP dialUdp;
uint32_t dialStreamBoot = 0, dialStreamSeq = 0;
DialStreamTarget dialStreamTarget;
dial_stream::Pacer dialStreamPacer, livePacer, iPhonePacer;
uint8_t iPhoneStreamPacket[3]{};
String cachedStreamHost;
IPAddress cachedStreamAddress;

bool lowLatencyDial(const HardwareBinding& binding, bool safety) {
    return !safety && binding.state.mode != BindingMode::action &&
        board.dialTracker().configuration().lowLatency && !std::strcmp(binding.inputID, "dial-1");
}
bool resolveStreamHost(const String& host, IPAddress& address) {
    if (address.fromString(host)) return true;
    if (host == cachedStreamHost) { address = cachedStreamAddress; return true; }
    // Hostnames are resolved once; the stream must not block on DNS for every value.
    if (!WiFi.hostByName(host.c_str(), address)) return false;
    cachedStreamHost = host;
    cachedStreamAddress = address;
    return true;
}
void sendDialDatagram() {
    char datagram[sizeof(Request::body) + sizeof(Request::token) + 96];
    const size_t length = dial_stream::writeDatagram(datagram, sizeof(datagram), dialStreamBoot,
        ++dialStreamSeq, dialStreamTarget.token.c_str(), dialStreamTarget.body.c_str());
    if (!length || !dialUdp.beginPacket(dialStreamTarget.address, dialStreamTarget.port)) return;
    dialUdp.write(reinterpret_cast<const uint8_t*>(datagram), length);
    dialUdp.endPacket();
}
bool streamDialDatagram(const String& host, int port, const char* token, const String& body) {
    IPAddress address;
    if (WiFi.status() != WL_CONNECTED || !resolveStreamHost(host, address)) return false;
    // A different target must not lose the previous target's final value.
    if (dialStreamPacer.active() && (address != dialStreamTarget.address || port != dialStreamTarget.port))
        sendDialDatagram();
    dialStreamTarget.address = address;
    dialStreamTarget.port = uint16_t(port);
    dialStreamTarget.token = token;
    dialStreamTarget.body = body;
    dialStreamPacer.offer();
    return true;
}
void notifyLiveDial() {
    uint8_t packet[7];
    const size_t length = dial_stream::encodeLiveDial(packet, board.dialTracker().shaftAngle(),
        board.dialTracker().positionDegrees());
    uint16_t handles[device_controls::HandleSet::capacity];
    size_t count = 0;
    portENTER_CRITICAL(&deviceControlLock);
    for (size_t i = 0; i < snapshotSubscribers.size(); ++i) handles[count++] = snapshotSubscribers.at(i);
    portEXIT_CRITICAL(&deviceControlLock);
    for (size_t i = 0; i < count; ++i) control->notify(packet, length, handles[i]);
}
void pollDialStream() {
    const auto& settings = board.dialTracker().configuration();
    dialStreamPacer.setRate(settings.rate);
    livePacer.setRate(settings.rate);
    iPhonePacer.setRate(settings.rate);
    const uint32_t now = micros();
    if (dialStreamPacer.poll(now) != dial_stream::Pacer::Send::none) sendDialDatagram();
    if (livePacer.poll(now) != dial_stream::Pacer::Send::none && control) notifyLiveDial();
    if (iPhonePacer.poll(now) != dial_stream::Pacer::Send::none && control &&
        iPhoneController != UINT16_MAX)
        control->notify(iPhoneStreamPacket, sizeof(iPhoneStreamPacket), iPhoneController);
}
#endif
bool dispatchAction(const HardwareBinding& binding, const NativeAction& action, bool safety = false) {
    if (!std::strcmp(action.type, "iPhoneMedia")) {
        if (iPhoneController == UINT16_MAX || !control) return false;
        const char* commands[] = {"playPause", "previous", "next", "volumeUp", "volumeDown",
            "mute", "seek", "volume"};
        for (uint8_t i = 0; i < sizeof(commands) / sizeof(commands[0]); ++i) {
            if (std::strcmp(action.text, commands[i])) continue;
            const uint8_t response[] = {0x60, uint8_t(i + 1), uint8_t(constrain(action.value, 0, 255))};
#if defined(PAPERGIF_SUPERMINI_S3)
            if (lowLatencyDial(binding, safety)) {
                std::memcpy(iPhoneStreamPacket, response, sizeof(response));
                iPhonePacer.offer();
                return true;
            }
#endif
            return control->notify(response, sizeof(response), iPhoneController);
        }
        return false;
    }
    JsonDocument json;
    String url, body, authority;
    const char* token = "";
    const char* method = "POST";
    int relayComputer = noRelayComputer;
    String streamHost;
    int streamPort = 0;
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
        } else if (!std::strcmp(action.type, "wledPreset")) json["ps"] = constrain(action.value, 1, 250);
        else json["bri"] = constrain(action.value, 0, 255);
    } else {
        auto computer = targetComputer(action);
        const char* host = computer["host"] | "";
        int port = computer["port"] | 43821;
        token = computer["token"] | "";
        if (computer.isNull() && !action.computerId[0]) {
            host = profileJSON["macHost"] | "";
            port = profileJSON["macPort"] | 43821;
            token = profileJSON["macToken"] | "";
        }
        if (!*token || port < 1 || port > 65535 || !localAuthority(host, authority)) return false;
        // Companion host fields are hostnames, not authorities with embedded ports.
        if (authority.indexOf(':') >= 0) return false;
        url = "http://" + authority + ":" + String(port) + "/action";
        streamHost = authority;
        streamPort = port;
        writeRemoteActionPayload(json, action);
        relayComputer = computerIndexFor(action);
    }
    if (body.isEmpty() && std::strcmp(action.type, "localHTTP")) serializeJson(json, body);
#if defined(PAPERGIF_SUPERMINI_S3)
    if (relayComputer != noRelayComputer && streamPort && lowLatencyDial(binding, safety) &&
        streamDialDatagram(streamHost, streamPort, token, body)) return true;
#endif
    // Without Wi-Fi, a companion that registered as a Bluetooth relay forwards the action.
    if (relayComputer != noRelayComputer && WiFi.status() != WL_CONNECTED &&
        relayHandleFor(relayComputer, false) != device_controls::RelayRegistry::none) {
        const bool slider = binding.state.mode != BindingMode::action && !safety;
        if (pendingRelaySlider.active &&
            (!slider || std::strcmp(pendingRelaySlider.controlId, binding.inputID) ||
             pendingRelaySlider.computer != relayComputer)) flushRelaySlider(true);
        if (slider) {
            pendingRelaySlider.active = true;
            pendingRelaySlider.computer = relayComputer;
            strlcpy(pendingRelaySlider.controlId, binding.inputID, sizeof(pendingRelaySlider.controlId));
            pendingRelaySlider.body = body;
            flushRelaySlider(false);
            return true;
        }
        if (sendRelayAction(relayComputer, false, body.c_str())) return true;
    }
    Request request;
    if (url.length() >= sizeof(request.url) || body.length() >= sizeof(request.body) ||
        std::strlen(token) >= sizeof(request.token)) return false;
    strlcpy(request.url, url.c_str(), sizeof(request.url));
    strlcpy(request.body, body.c_str(), sizeof(request.body));
    strlcpy(request.token, token, sizeof(request.token));
    strlcpy(request.method, method, sizeof(request.method));
    strlcpy(request.controlId, binding.inputID, sizeof(request.controlId));
    request.slider = binding.state.mode != BindingMode::action;
    request.profileRevision = profileRevision;
    request.relayComputer = static_cast<int8_t>(relayComputer >= -1 ? relayComputer : noRelayComputer);
    xSemaphoreTake(networkMutex, portMAX_DELAY);
    // A release/cancel must not sit behind stale high-rate value changes.
    if (safety) networkQueue.clearPending();
    const bool queued = networkQueue.enqueue(request);
    xSemaphoreGive(networkMutex);
    return queued;
}
void networkWorker(void*) {
    for (;;) {
        Request request;
        xSemaphoreTake(networkMutex, portMAX_DELAY);
        const bool available = networkQueue.take(request);
        xSemaphoreGive(networkMutex);
        if (available) {
            HTTPClient http;
            WiFiClient client;
            http.setConnectTimeout(750);
            http.setTimeout(1000);
            http.setFollowRedirects(HTTPC_DISABLE_FOLLOW_REDIRECTS);
            if (http.begin(client, request.url)) {
                http.addHeader("Content-Type", "application/json");
                if (request.token[0]) http.addHeader("Authorization", String("Bearer ") + request.token);
                const int result = !std::strcmp(request.method, "GET") ? http.GET()
                    : http.POST(reinterpret_cast<uint8_t*>(request.body), std::strlen(request.body));
                if (result < 200 || result >= 300) Serial.printf("Action failed: HTTP %d\n", result);
                http.end();
                // Connect failures mean the computer never saw the action; retry once over a
                // direct Bluetooth relay from the loop task.
                if (result == HTTPC_ERROR_CONNECTION_REFUSED && request.relayComputer != noRelayComputer &&
                    relayRetries && relayHandleFor(request.relayComputer, true) != device_controls::RelayRegistry::none) {
                    RelayRetry* retry = new (std::nothrow) RelayRetry;
                    if (retry) {
                        retry->computer = request.relayComputer;
                        strlcpy(retry->body, request.body, sizeof(retry->body));
                        if (xQueueSend(relayRetries, &retry, 0) != pdTRUE) delete retry;
                    }
                }
            }
            xSemaphoreTake(networkMutex, portMAX_DELAY);
            networkQueue.finish();
            xSemaphoreGive(networkMutex);
        }
        vTaskDelay(pdMS_TO_TICKS(2));
    }
}
void handleInput(const InputEvent& event) {
    if (!std::strcmp(event.event, "release")) {
        xSemaphoreTake(networkMutex, portMAX_DELAY);
        networkQueue.clearPending();
        xSemaphoreGive(networkMutex);
    }
    for (size_t i = 0; i < board.info().inputCount; ++i) {
        if (std::strcmp(board.info().inputs[i].id, event.inputID)) continue;
        if (!std::strcmp(event.event, "press")) pressed[i] = true;
        else if (!std::strcmp(event.event, "release")) pressed[i] = false;
    }
    dispatchHardwareInput(profile, board.info(), event,
        [](const HardwareBinding& binding, const NativeAction& action) {
            return dispatchAction(binding, action);
        });
}
void releaseInputs() {
    xSemaphoreTake(networkMutex, portMAX_DELAY);
    networkQueue.clearPending();
    xSemaphoreGive(networkMutex);
    releaseHardwareInputs(profile, board.info(), pressed,
        [](const HardwareBinding& binding, const NativeAction& action) { return dispatchAction(binding, action); });
    board.inputs()->release();
}
bool authorized() {
    if (!configured) return server.client().localIP() == WiFi.softAPIP();
    const String header = server.header("Authorization");
    if (!header.startsWith("Bearer ")) return false;
    const String token = header.substring(7);
    if (token.isEmpty()) return false;
    if (token == (profileJSON["macToken"] | "")) return true;
    for (JsonObjectConst computer : profileJSON["computers"].as<JsonArrayConst>())
        if (token == (computer["token"] | "")) return true;
    return false;
}
bool installProfile(const String& payload, bool persist) {
    profileError = "invalid_profile";
    if (!payload.length() || payload.length() > board.info().maxProfileBytes) return false;
    JsonDocument candidate;
    // Allocate the large candidate on the heap, never the small ESP32 loop stack.
    auto* parsed = new (std::nothrow) NativeProfile;
    const bool valid = parsed && !deserializeJson(candidate, payload, DeserializationOption::NestingLimit(24)) &&
        parseNativeProfile(candidate, *parsed, board.info(), &profileError);
    if (!valid) { delete parsed; return false; }
    // Refuse profiles that would make subsequent authenticated editing impossible.
    bool hasToken = std::strlen(candidate["macToken"] | "") > 0;
    for (JsonObjectConst computer : candidate["computers"].as<JsonArrayConst>())
        hasToken = hasToken || std::strlen(computer["token"] | "") > 0;
    if (!hasToken) { profileError = "missing_profile_token"; delete parsed; return false; }
    if (persist) {
        if (!storageReady) { delete parsed; return false; }
        LittleFS.remove("/remote.new");
        File file = LittleFS.open("/remote.new", FILE_WRITE);
        const bool written = file && file.print(payload) == payload.length();
        if (file) { file.flush(); file.close(); }
        if (!written) { LittleFS.remove("/remote.new"); delete parsed; return false; }
        LittleFS.remove("/remote.bak");
        if (LittleFS.exists("/remote.json") && !LittleFS.rename("/remote.json", "/remote.bak")) {
            delete parsed; return false;
        }
        if (!LittleFS.rename("/remote.new", "/remote.json")) {
            LittleFS.rename("/remote.bak", "/remote.json");
            delete parsed; return false;
        }
    }
    releaseInputs();
    profileJSON = std::move(candidate);
    profile = *parsed;
    delete parsed;
    ++profileRevision;
    configured = true;
    // A profile that names a network replaces credentials set from the network picker.
    if (persist && *(profileJSON["wifiSSID"] | "") && setupCredentials.ssid[0]) {
        setupCredentials = wifi_setup::Credentials{};
        if (wifiStorageReady) wifiPreferences.clear();
    }
    stationConnectPending = true;
    return true;
}
struct Upload {
    String bytes;
    uint32_t expected = 0, crc = 0;
    uint32_t nextAck = 16384, lastActivity = 0;
    uint16_t owner = UINT16_MAX;
    bool finish = false;
} upload;
QueueHandle_t bleWrites;
struct BLEWrite {
    uint16_t handle, length;
    bool command;
    uint8_t bytes[512];
};
class WriteCallbacks final : public NimBLECharacteristicCallbacks {
    bool command;
public:
    explicit WriteCallbacks(bool value) : command(value) {}
    void onWrite(NimBLECharacteristic* characteristic, NimBLEConnInfo& info) override {
        const auto value = characteristic->getValue();
        BLEWrite packet{};
        if (value.size() > sizeof(packet.bytes)) return;
        packet.handle = info.getConnHandle();
        packet.length = value.size(); packet.command = command;
        std::memcpy(packet.bytes, value.data(), value.size());
        if (xQueueSend(bleWrites, &packet, 0) != pdTRUE) disconnected = true;
    }
} controlCallbacks(true), dataCallbacks(false);
class ServerCallbacks final : public NimBLEServerCallbacks {
    void onConnect(NimBLEServer* server, NimBLEConnInfo&) override {
        // Keep a slot discoverable so a phone and a computer relay can both connect.
        if (server->getConnectedCount() < CONFIG_BT_NIMBLE_MAX_CONNECTIONS) NimBLEDevice::startAdvertising();
    }
    void onDisconnect(NimBLEServer*, NimBLEConnInfo& info, int) override {
        const uint16_t handle = info.getConnHandle();
        descriptorCallbacks.disconnected(handle);
        portENTER_CRITICAL(&deviceControlLock);
        const bool relayOnly = relays.isRelay(handle) && !snapshotSubscribers.contains(handle);
        relays.removeHandle(handle);
        snapshotSubscribers.remove(handle);
        relaySequences.removeHandle(handle);
        portEXIT_CRITICAL(&deviceControlLock);
        const bool controller = iPhoneController == handle || upload.owner == handle;
        if (iPhoneController == handle) iPhoneController = UINT16_MAX;
        // A relay-only companion leaving must not release inputs held by another controller.
        if (!relayOnly || controller) disconnected = true;
    }
} serverCallbacks;
uint32_t read32(const uint8_t* p) {
    return uint32_t(p[0]) | uint32_t(p[1]) << 8 | uint32_t(p[2]) << 16 | uint32_t(p[3]) << 24;
}
uint32_t crc32(const String& bytes) {
    uint32_t result = UINT32_MAX;
    for (size_t i = 0; i < bytes.length(); ++i) {
        result ^= uint8_t(bytes[i]);
        for (int bit = 0; bit < 8; ++bit) result = (result >> 1) ^ (0xedb88320U & (0U - (result & 1)));
    }
    return ~result;
}
void notify(uint8_t code, uint16_t handle) { control->notify(&code, 1, handle); }
bool readControl(const device_controls::Control& item, device_controls::Value& value) {
    const bool online = WiFi.status() == WL_CONNECTED;
    switch (&item - reference_controls::controls) {
    case reference_controls::wifiConnected: value.boolean = online; return true;
    case reference_controls::wifiSignal:
        if (!online) return false;
        value.number = constrain(WiFi.RSSI(), -100, 0);
        return true;
#if defined(PAPERGIF_SUPERMINI_S3)
    case reference_controls::dialPresent: value.boolean = board.dialPresent(); return true;
    case reference_controls::dialPosition:
        if (!board.dialPresent() || !board.dialTracker().ready()) return false;
        value.number = std::round(board.dialTracker().positionDegrees() * 100) / 100; return true;
    case reference_controls::dialAngle:
        if (!board.dialPresent() || !board.dialTracker().ready()) return false;
        value.number = std::round(board.dialTracker().shaftAngle() * 100) / 100; return true;
    case reference_controls::dialOutput:
        if (!board.dialPresent() || !board.dialTracker().ready()) return false;
        value.number = board.dialTracker().outputPercent(); return true;
    case reference_controls::dialMode:
        value.text = reference_controls::dialModes[int(board.dialTracker().configuration().mode)].value;
        return true;
    case reference_controls::dialStart: value.number = board.dialTracker().configuration().start; return true;
    case reference_controls::dialSweep: value.number = board.dialTracker().configuration().sweep; return true;
    case reference_controls::dialTurns: value.number = board.dialTracker().configuration().turns; return true;
    case reference_controls::dialStep: value.number = board.dialTracker().configuration().step; return true;
    case reference_controls::dialJitter: value.number = board.dialTracker().configuration().jitter; return true;
    case reference_controls::dialLowLatency: value.boolean = board.dialTracker().configuration().lowLatency; return true;
    case reference_controls::dialRate: value.number = board.dialTracker().configuration().rate; return true;
#endif
    default: return false;
    }
}
String controlsJSON(bool okResponse) {
    JsonDocument json;
    if (okResponse) json["ok"] = true;
    device_controls::writeSnapshot(json["values"].to<JsonObject>(), reference_controls::controls,
        reference_controls::count, readControl);
    String result;
    serializeJson(json, result);
    return result;
}
device_controls::Status applyControl(const device_controls::Control& item, const device_controls::Value& value) {
#if defined(PAPERGIF_SUPERMINI_S3)
    const auto index = &item - reference_controls::controls;
    if (index >= reference_controls::dialMode && index <= reference_controls::dialZero) {
        if (upload.owner != UINT16_MAX) return device_controls::Status::busy;
        if (index == reference_controls::dialZero) {
            if (!board.dialPresent()) return device_controls::Status::busy;
            auto origin = board.dialTracker().configuration();
            origin.start = std::min(359.9, board.dialTracker().shaftAngle());
            const String settings = dialConfigurationJSON(origin);
            if (!dialStorageReady || dialPreferences.putString("settings", settings) != settings.length()) {
                Serial.println("Could not persist dial zero");
                return device_controls::Status::busy;
            }
            board.configureDial(origin);
            board.dialTracker().zero();
            return device_controls::Status::ok;
        }
        auto candidate = board.dialTracker().configuration();
        switch (index) {
        case reference_controls::dialMode:
            for (int i = 0; i < 3; ++i)
                if (!std::strcmp(value.text, reference_controls::dialModes[i].value))
                    candidate.mode = static_cast<DialMode>(i);
            break;
        case reference_controls::dialStart: candidate.start = value.number; break;
        case reference_controls::dialSweep: candidate.sweep = value.number; break;
        case reference_controls::dialTurns: candidate.turns = value.number; break;
        case reference_controls::dialStep: candidate.step = value.number; break;
        case reference_controls::dialJitter: candidate.jitter = value.number; break;
        case reference_controls::dialLowLatency: candidate.lowLatency = value.boolean; break;
        case reference_controls::dialRate: candidate.rate = value.number; break;
        }
        if (!candidate.valid()) return device_controls::Status::invalidValue;
        const String settings = dialConfigurationJSON(candidate);
        if (!dialStorageReady || dialPreferences.putString("settings", settings) != settings.length()) {
            Serial.println("Could not persist dial settings");
            return device_controls::Status::busy;
        }
        board.configureDial(candidate);
        return device_controls::Status::ok;
    }
#else
    (void)value;
#endif
    if (&item - reference_controls::controls != reference_controls::restart) return device_controls::Status::readOnly;
    if (restartPending || upload.owner != UINT16_MAX) return device_controls::Status::busy;
    restartPending = true;
    restartAt = millis() + restartDelayMs;
    return device_controls::Status::ok;
}
// Sends a snapshot to `requester` and, when `subscribers` is set, to every subscriber.
void sendSnapshot(uint16_t requester, bool subscribers) {
    const String json = controlsJSON(false);
    uint16_t handles[device_controls::HandleSet::capacity + 1];
    size_t count = 0;
    if (requester != UINT16_MAX) handles[count++] = requester;
    if (subscribers) {
        portENTER_CRITICAL(&deviceControlLock);
        for (size_t i = 0; i < snapshotSubscribers.size(); ++i)
            if (snapshotSubscribers.at(i) != requester) handles[count++] = snapshotSubscribers.at(i);
        portEXIT_CRITICAL(&deviceControlLock);
        lastSnapshot = json;
    }
    const uint8_t header[] = {device_controls::snapshotFragment};
    for (size_t i = 0; i < count; ++i) sendFragmented(handles[i], header, sizeof(header), json);
}
void handleRelayRegistration(uint16_t handle, const uint8_t* data, size_t length) {
    String response;
    response += char(device_controls::relayRegistered);
    response += char(1);
    if (configured && length >= 3 && data[1] <= 1) {
        JsonArrayConst computers = profileJSON["computers"].as<JsonArrayConst>();
        const int computer = device_controls::tokenComputerIndex(
            reinterpret_cast<const char*>(data + 2), length - 2, profileJSON["macToken"] | "",
            computers.size(), [&computers](size_t index) { return computers[index]["token"] | ""; });
        if (computer != -2) {
            portENTER_CRITICAL(&deviceControlLock);
            const bool added = relays.add(handle, computer, static_cast<device_controls::RelayRole>(data[1]));
            portEXIT_CRITICAL(&deviceControlLock);
            if (added) {
                response[1] = 0;
                if (computer >= 0) response += (computers[computer]["id"] | "");
                Serial.printf("BLE relay registered: handle=%u computer=%d role=%u\n", handle, computer, data[1]);
            }
        }
    }
    notifyPacket(handle, reinterpret_cast<const uint8_t*>(response.c_str()), response.length());
}
// Handles device-control and relay opcodes; returns false for other packets.
bool processDeviceControlPacket(const uint8_t* bytes, size_t length, uint16_t handle) {
    const uint8_t opcode = bytes[0];
    if (opcode == device_controls::snapshotRequest) {
        if (length != 1) return true;
        portENTER_CRITICAL(&deviceControlLock);
        snapshotSubscribers.add(handle);
        portEXIT_CRITICAL(&deviceControlLock);
        sendSnapshot(handle, false);
    } else if (opcode == device_controls::setRequest) {
        const device_controls::Control* item = nullptr;
        device_controls::Value value;
        device_controls::Status status = device_controls::parseSetRequest(
            reinterpret_cast<const char*>(bytes + 1), length - 1, reference_controls::controls,
            reference_controls::count, item, value);
        if (status == device_controls::Status::ok) status = applyControl(*item, value);
        const uint8_t response[] = {device_controls::setResult, uint8_t(status)};
        notifyPacket(handle, response, sizeof(response));
        if (status == device_controls::Status::ok) sendSnapshot(handle, true);
    } else if (opcode == device_controls::relayRegister) {
        handleRelayRegistration(handle, bytes, length);
    } else if (opcode == device_controls::relayResult) {
        if (length != 3) return true;
        portENTER_CRITICAL(&deviceControlLock);
        const bool known = relaySequences.complete(handle, bytes[1]);
        portEXIT_CRITICAL(&deviceControlLock);
        if (known && bytes[2] != 0) Serial.printf("BLE relay action seq=%u failed (%u)\n", bytes[1], bytes[2]);
    } else {
        return false;
    }
    return true;
}
void pollDeviceControls() {
    RelayRetry* retry = nullptr;
    while (relayRetries && xQueueReceive(relayRetries, &retry, 0) == pdTRUE) {
        if (sendRelayAction(retry->computer, true, retry->body)) Serial.println("Sent via Bluetooth");
        delete retry;
    }
    if (restartPending && int32_t(millis() - restartAt) >= 0) {
        Serial.println("Restarting by device control");
        Serial.flush();
        ESP.restart();
    }
    const uint32_t interval =
#if defined(PAPERGIF_SUPERMINI_S3)
        dialSnapshotCheckMs;
#else
        snapshotCheckMs;
#endif
    if (millis() - snapshotCheckedAt < interval) return;
    snapshotCheckedAt = millis();
    portENTER_CRITICAL(&deviceControlLock);
    const bool subscribed = snapshotSubscribers.size() > 0;
    portEXIT_CRITICAL(&deviceControlLock);
    if (subscribed && controlsJSON(false) != lastSnapshot) sendSnapshot(UINT16_MAX, true);
}
void sendControlsError(int status, const char* error) {
    JsonDocument json;
    device_controls::writeError(json, error);
    String response;
    serializeJson(json, response);
    server.send(status, "application/json", response);
}
void pollBLEUploadTimeout() {
    expireIdleUpload(upload, millis(), [](uint16_t owner) { notify(0x7f, owner); });
}
const char* stationSSID() {
    return setupCredentials.ssid[0] ? setupCredentials.ssid : (profileJSON["wifiSSID"] | "");
}
const char* stationPassword() {
    return setupCredentials.ssid[0] ? setupCredentials.password : (profileJSON["wifiPassword"] | "");
}
void startStation() {
    const char* ssid = stationSSID();
    if (!*ssid) {
        wifiJoin.notConfigured();
        Serial.println("Wi-Fi not configured; choose a network in the phone's Device Setup");
        return;
    }
    Serial.printf("Wi-Fi joining \"%s\"\n", ssid);
    lastDisconnectReason = 0;
    wifiJoin.begin(millis());
    WiFi.begin(ssid, stationPassword());
#if defined(PAPERGIF_SUPERMINI_S3)
    // The SuperMini's chip antenna can't associate at full power; begin() resets the limit, so set it after.
    WiFi.setTxPower(PAPERGIF_WIFI_TX_POWER);
#endif
}
// Pushes to every subscriber when `handle` is UINT16_MAX.
void sendWiFiStatus(uint16_t handle) {
    if (!control) return;
    uint8_t frame[wifi_setup::maxStatusBytes];
    const IPAddress address = WiFi.localIP();
    const uint8_t ip[] = {address[0], address[1], address[2], address[3]};
    const size_t length = wifi_setup::encodeStatus(frame, wifiJoin.state(), wifiJoin.why(), ip, stationSSID());
    if (handle == UINT16_MAX) control->notify(frame, length);
    else notifyPacket(handle, frame, length);
}
void finishWiFiScan() {
    const int16_t found = WiFi.scanComplete();
    if (wifiScanRequester == UINT16_MAX || found == WIFI_SCAN_RUNNING) return;
    scannedNetworkCount = 0;
    for (int16_t i = 0; i < found; ++i) {
        const String ssid = WiFi.SSID(i);
        Serial.printf("Wi-Fi scan: \"%s\" rssi=%d ch=%d\n", ssid.c_str(), WiFi.RSSI(i), WiFi.channel(i));
        if (ssid.isEmpty() || ssid.length() > wifi_setup::maxSSID) continue;
        const int8_t rssi = static_cast<int8_t>(constrain(WiFi.RSSI(i), -127, 0));
        size_t slot = scannedNetworkCount;
        for (size_t known = 0; known < scannedNetworkCount; ++known)
            if (ssid == scannedNetworks[known].ssid) { slot = known; break; }
        if (slot < scannedNetworkCount) {
            if (rssi > scannedNetworks[slot].rssi) scannedNetworks[slot].rssi = rssi;
            continue;
        }
        if (scannedNetworkCount == maxScanNetworks) {
            // Keep the strongest networks.
            size_t weakest = 0;
            for (size_t known = 1; known < maxScanNetworks; ++known)
                if (scannedNetworks[known].rssi < scannedNetworks[weakest].rssi) weakest = known;
            if (scannedNetworks[weakest].rssi >= rssi) continue;
            slot = weakest;
        } else ++scannedNetworkCount;
        std::strncpy(scannedNetworks[slot].ssid, ssid.c_str(), wifi_setup::maxSSID);
        scannedNetworks[slot].ssid[wifi_setup::maxSSID] = 0;
        scannedNetworks[slot].rssi = rssi;
        scannedNetworks[slot].secure = WiFi.encryptionType(i) != WIFI_AUTH_OPEN;
    }
    if (found >= 0) WiFi.scanDelete();
    std::sort(scannedNetworks, scannedNetworks + scannedNetworkCount,
              [](const ScannedNetwork& a, const ScannedNetwork& b) { return a.rssi > b.rssi; });
    Serial.printf("Wi-Fi scan found %u networks\n", unsigned(scannedNetworkCount));
    const uint8_t reply[] = {wifi_setup::networkCount, uint8_t(scannedNetworkCount)};
    notifyPacket(wifiScanRequester, reply, sizeof(reply));
    wifiScanRequester = UINT16_MAX;
    if (wifiScanResume) { wifiScanResume = false; startStation(); }
}
bool wifiSetupAllowed(uint16_t handle) {
    if (!configured) return true;
    portENTER_CRITICAL(&deviceControlLock);
    const bool relay = relays.isRelay(handle);
    portEXIT_CRITICAL(&deviceControlLock);
    return relay;
}
bool processWiFiSetupPacket(const uint8_t* bytes, size_t length, uint16_t handle) {
    switch (bytes[0]) {
    case wifi_setup::scanRequest: {
        if (length != 1) return false;
        if (wifiScanRequester != UINT16_MAX) { wifiScanRequester = handle; return true; }
        // The radio cannot scan while it is still trying to join; pause the attempt.
        wifiScanResume = WiFi.status() != WL_CONNECTED && *stationSSID();
        if (wifiScanResume) WiFi.disconnect(false, false);
        if (WiFi.scanNetworks(true, false) == WIFI_SCAN_FAILED) {
            const uint8_t reply[] = {wifi_setup::networkCount, 0};
            notifyPacket(handle, reply, sizeof(reply));
            if (wifiScanResume) { wifiScanResume = false; startStation(); }
            return true;
        }
        wifiScanRequester = handle;
        return true;
    }
    case wifi_setup::networkRead: {
        if (length != 2 || bytes[1] >= scannedNetworkCount) { notify(wifi_setup::failed, handle); return true; }
        const ScannedNetwork& network = scannedNetworks[bytes[1]];
        uint8_t reply[wifi_setup::maxNetworkBytes];
        notifyPacket(handle, reply, wifi_setup::encodeNetwork(reply, bytes[1], network.rssi, network.secure, network.ssid));
        return true;
    }
    case wifi_setup::statusRequest:
        if (length != 1) return false;
        sendWiFiStatus(handle);
        return true;
    case wifi_setup::joinRequest: {
        wifi_setup::Credentials credentials;
        uint16_t rejected = wifi_setup::reason::none;
        if (!wifi_setup::parseJoin(bytes, length, credentials)) rejected = wifi_setup::reason::invalidRequest;
        else if (!wifiSetupAllowed(handle)) rejected = wifi_setup::reason::unauthorized;
        else if (wifiStorageReady && (!wifiPreferences.putString("ssid", credentials.ssid) ||
                 wifiPreferences.putString("password", credentials.password) != std::strlen(credentials.password)))
            rejected = wifi_setup::reason::storageFailed;
        if (rejected) {
            // Report the rejected request without changing the tracked connection.
            uint8_t frame[wifi_setup::maxStatusBytes];
            const uint8_t none[4] = {};
            notifyPacket(handle, frame, wifi_setup::encodeStatus(frame, wifi_setup::State::failed, rejected, none,
                                                                 credentials.ssid));
            return true;
        }
        setupCredentials = credentials;
        wifiScanResume = false;
        WiFi.disconnect(false, false);
        startStation();
        sendWiFiStatus(UINT16_MAX);
        return true;
    }
    default:
        return false;
    }
}
void processBLE() {
    BLEWrite packet;
    while (xQueueReceive(bleWrites, &packet, 0) == pdTRUE) {
        if (packet.command) {
            if (packet.length > 0 && processDeviceControlPacket(packet.bytes, packet.length, packet.handle)) continue;
            if (packet.length > 0 && processWiFiSetupPacket(packet.bytes, packet.length, packet.handle)) continue;
            if (packet.length == 1 && packet.bytes[0] == 0x62) {
                iPhoneController = packet.handle;
                continue;
            }
            if ((packet.length >= 12 && packet.bytes[0] == 0x61) ||
                (packet.length >= 2 && packet.bytes[0] == 0x63)) continue;
            if (packet.length == 9 && packet.bytes[0] == 0x40 && upload.owner == UINT16_MAX) {
                const uint32_t size = read32(packet.bytes + 1);
                if (size == 0 || size > board.info().maxProfileBytes) { notify(0x7f, packet.handle); continue; }
                upload.bytes = "";
                upload.bytes.reserve(size);
                upload.expected = size; upload.crc = read32(packet.bytes + 5);
                upload.owner = packet.handle; upload.finish = false;
                upload.nextAck = std::min(uint32_t(16384), size);
                upload.lastActivity = millis();
                notify(0x41, packet.handle);
            } else if (packet.length == 1 && packet.bytes[0] == 0x42 && upload.owner == packet.handle) {
                upload.finish = true;
                upload.lastActivity = millis();
            } else notify(0x7f, packet.handle);
        } else if (upload.owner == packet.handle && upload.bytes.length() + packet.length <= upload.expected) {
            upload.bytes.concat(reinterpret_cast<const char*>(packet.bytes), packet.length);
            upload.lastActivity = millis();
            if (upload.bytes.length() >= upload.nextAck) {
                const uint32_t size = upload.bytes.length();
                const uint8_t response[] = {0x45, uint8_t(size), uint8_t(size >> 8),
                    uint8_t(size >> 16), uint8_t(size >> 24)};
                control->notify(response, sizeof(response), upload.owner);
                upload.nextAck = std::min(upload.expected, upload.nextAck + 16384);
            }
            if (upload.bytes.length() == upload.expected) notify(0x44, packet.handle);
        } else notify(0x7f, packet.handle);
        if (upload.owner != UINT16_MAX && upload.finish && upload.bytes.length() == upload.expected) {
            const bool ok = crc32(upload.bytes) == upload.crc && installProfile(upload.bytes, true);
            if (!ok) Serial.printf("BLE profile rejected: %s\n", profileError);
            notify(ok ? 0x43 : 0x7f, upload.owner);
            upload = Upload{};
        }
    }
}
} // namespace

void setup() {
    Serial.begin(115200);
    Serial.println(deviceFirmwareIdentity);
#if defined(PAPERGIF_SUPERMINI_S3)
    dialStreamBoot = esp_random();
    loadDialConfiguration();
#endif
    board.begin();
#if defined(PAPERGIF_SUPERMINI_S3)
    {
        uint16_t angle = 0;
        if (board.readDialForDiagnostics(angle)) Serial.printf("MT6701 ready: angle=%u\n", angle);
        else Serial.println("MT6701 not responding on I2C 0x06; check SDA/SCL wiring");
    }
#endif
    deviceJSON = descriptor(board.info(), PAPERGIF_FIRMWARE_VERSION,
        reference_controls::controls, reference_controls::count);
    networkMutex = xSemaphoreCreateMutex();
    bleWrites = xQueueCreate(12, sizeof(BLEWrite));
    relayRetries = xQueueCreate(4, sizeof(RelayRetry*));
    if (!networkMutex || !bleWrites || !relayRetries) { Serial.println("Allocation failed"); abort(); }
    storageReady = mountReferenceStorage(LittleFS,
        PAPERGIF_REFERENCE_FORMAT_ON_MOUNT_FAILURE != 0,
        [](const char* message) { Serial.println(message); });
    if (!storageReady) {
        Serial.println("Profile storage unavailable; preserving flash. Provision with the explicit format opt-in build.");
    }
    if (storageReady) {
        const char* paths[] = {"/remote.json", "/remote.bak"};
        for (auto path : paths) {
            File file = LittleFS.open(path, FILE_READ);
            if (file && file.size() <= board.info().maxProfileBytes && installProfile(file.readString(), false)) {
                file.close(); break;
            }
            if (file) file.close();
        }
    }
    wifiStorageReady = wifiPreferences.begin("papergif-wifi", false);
    if (wifiStorageReady) {
        wifiPreferences.getString("ssid", setupCredentials.ssid, sizeof(setupCredentials.ssid));
        wifiPreferences.getString("password", setupCredentials.password, sizeof(setupCredentials.password));
    }
    WiFi.onEvent([](WiFiEvent_t, WiFiEventInfo_t info) {
        lastDisconnectReason = info.wifi_sta_disconnected.reason;
    }, ARDUINO_EVENT_WIFI_STA_DISCONNECTED);
    WiFi.persistent(false);
    WiFi.mode(WIFI_AP_STA);
    char name[32];
    snprintf(name, sizeof(name), "papergif-%04x", unsigned(ESP.getEfuseMac() & 0xffff));
    WiFi.softAP(name, "paperdisplay");
    Serial.printf("Reference AP %s: %s\n", name, WiFi.softAPIP().toString().c_str());
    const char* headers[] = {"Authorization"};
    server.collectHeaders(headers, 1);
    server.on("/device", HTTP_GET, [] { server.send(200, "application/json", deviceJSON); });
    server.on("/status", HTTP_GET, [] {
        server.send(200, "application/json", storageReady
            ? "{\"device\":\"paperGIF\",\"ready\":true,\"uploading\":false}"
            : "{\"device\":\"paperGIF\",\"ready\":false,\"uploading\":false}");
    });
#if defined(PAPERGIF_SUPERMINI_S3)
    server.on("/debug/inputs", HTTP_GET, [] {
        auto& supermini = static_cast<SuperMiniS3Board&>(board);
        uint16_t angle = 0;
        JsonDocument status;
        status["boardID"] = board.info().id;
        status["button1Pressed"] = supermini.buttonPressedForDiagnostics(0);
        status["button2Pressed"] = supermini.buttonPressedForDiagnostics(1);
        status["mt6701Present"] = supermini.readDialForDiagnostics(angle);
        status["angle"] = angle;
        if (hasLastSuperminiInput) {
            status["lastInputID"] = lastSuperminiInput.inputID;
            status["lastEvent"] = lastSuperminiInput.event;
            status["lastValue"] = lastSuperminiInput.value;
            status["lastSequence"] = lastSuperminiInput.sequence;
        }
        String response;
        serializeJson(status, response);
        server.send(200, "application/json", response);
    });
#endif
    server.on("/remote", HTTP_GET, [] {
        if (!authorized()) { server.send(401, "application/json", "{\"error\":\"unauthorized\"}"); return; }
        if (!configured) { server.send(404, "application/json", "{\"error\":\"profile_not_found\"}"); return; }
        String response;
        serializeJson(profileJSON, response);
        server.send(200, "application/json", response);
    });
    server.on("/remote", HTTP_POST, [] {
        if (!authorized()) { server.send(401, "application/json", "{\"error\":\"unauthorized\"}"); return; }
        if (!storageReady) {
            server.send(503, "application/json", "{\"error\":\"storage_unavailable\"}");
            return;
        }
        const bool ok = upload.owner == UINT16_MAX && installProfile(server.arg("plain"), true);
        server.send(ok ? 201 : 400, "application/json",
            ok ? String("{\"ok\":true}") : String("{\"error\":\"") + profileError + "\"}");
    });
    server.on("/device/controls", HTTP_GET, [] {
        if (!authorized()) { sendControlsError(401, "unauthorized"); return; }
        server.send(200, "application/json", controlsJSON(false));
    });
    server.on("/device/controls", HTTP_POST, [] {
        if (!authorized()) { sendControlsError(401, "unauthorized"); return; }
        const String body = server.arg("plain");
        const device_controls::Control* item = nullptr;
        device_controls::Value value;
        device_controls::Status status = device_controls::parseSetRequest(body.c_str(), body.length(),
            reference_controls::controls, reference_controls::count, item, value);
        if (status == device_controls::Status::ok) status = applyControl(*item, value);
        if (status != device_controls::Status::ok) {
            sendControlsError(device_controls::httpStatus(status), device_controls::errorName(status));
            return;
        }
        server.send(200, "application/json", controlsJSON(true));
        sendSnapshot(UINT16_MAX, true);
    });
    server.begin();
    if (MDNS.begin(name)) MDNS.addService("papergif-device", "tcp", 80);
    NimBLEDevice::init(bluetoothDeviceName);
    NimBLEDevice::setMTU(517);
    auto* bleServer = NimBLEDevice::createServer();
    bleServer->setCallbacks(&serverCallbacks, false);
    bleServer->advertiseOnDisconnect(true);
    auto* service = bleServer->createService(serviceUuid);
    control = service->createCharacteristic(controlUuid, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::NOTIFY, 256);
    auto* data = service->createCharacteristic(dataUuid, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR, 512);
    control->setCallbacks(&controlCallbacks);
    data->setCallbacks(&dataCallbacks);
    addDescriptorCharacteristic(service, descriptorCallbacks);
    bleServer->start();
    NimBLEDevice::getAdvertising()->addServiceUUID(serviceUuid);
    // The 128-bit service UUID fills the advertisement; the name goes in the scan response.
    NimBLEDevice::getAdvertising()->enableScanResponse(true);
    NimBLEDevice::getAdvertising()->setName(bluetoothDeviceName);
    NimBLEDevice::getAdvertising()->start();
    if (xTaskCreate(networkWorker, "actions", 8192, nullptr, 1, nullptr) != pdPASS) abort();
}
void loop() {
    descriptorCallbacks.poll(millis());
    pollBLEUploadTimeout();
    if (disconnected) {
        disconnected = false;
        releaseInputs();
        upload = Upload{};
        xQueueReset(bleWrites);
    }
    if (stationConnectPending) {
        stationConnectPending = false;
        // Re-installing a profile must not drop a working connection to the same network.
        if (!(WiFi.status() == WL_CONNECTED && WiFi.SSID() == stationSSID()) && wifiScanRequester == UINT16_MAX)
            startStation();
    }
    finishWiFiScan();
    static bool connected = false;
    static wl_status_t lastStatus = WL_IDLE_STATUS;
    const wl_status_t status = WiFi.status();
    const bool nowConnected = status == WL_CONNECTED;
    if (status != lastStatus) {
        if (nowConnected) Serial.printf("Wi-Fi connected: %s\n", WiFi.localIP().toString().c_str());
        else if (lastStatus == WL_CONNECTED) Serial.println("Wi-Fi lost; using Bluetooth");
        lastStatus = status;
    }
    if (wifiScanRequester == UINT16_MAX && !wifiScanResume &&
        wifiJoin.update(nowConnected, lastDisconnectReason, millis())) {
        if (wifiJoin.state() == wifi_setup::State::failed)
            Serial.printf("Wi-Fi join failed (reason %u)%s\n", wifiJoin.why(),
                          wifiJoin.why() == wifi_setup::reason::noAccessPoint ? ": network not found; the ESP32-S3 needs 2.4 GHz"
                          : wifi_setup::definitiveFailure(wifiJoin.why()) ? ": check the password" : "");
        sendWiFiStatus(UINT16_MAX);
    }
    if (connected && !nowConnected) releaseInputs();
    connected = nowConnected;
    server.handleClient();
    processBLE();
    pollDeviceControls();
    flushRelaySlider(false);
    InputEvent event;
    for (int i = 0; i < 8 && board.inputs()->poll(event); ++i) {
#if defined(PAPERGIF_SUPERMINI_S3)
        lastSuperminiInput = event;
        hasLastSuperminiInput = true;
        const bool streamed = board.dialTracker().configuration().lowLatency && !std::strcmp(event.inputID, "dial-1");
        // At stream rates the serial log would block the loop; log only discrete inputs.
        if (!streamed) Serial.printf("Input %s %s value=%.0f seq=%lu\n", event.inputID, event.event,
                      event.value, static_cast<unsigned long>(event.sequence));
        else livePacer.offer();
#endif
        handleInput(event);
    }
#if defined(PAPERGIF_SUPERMINI_S3)
    pollDialStream();
#endif
    delay(1);
}
