#include "network.h"
#include "remote_network_queue.h"
#include "dial_stream.h"
#include "esp_event.h"
#include "esp_http_client.h"
#include "esp_http_server.h"
#include "esp_netif.h"
#include "esp_random.h"
#include "esp_timer.h"
#include "esp_wifi.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "nvs.h"
#include "mdns.h"
#include "lwip/sockets.h"
#include "lwip/netdb.h"
#include <cerrno>
#include <fcntl.h>
#include <new>

namespace native_device {
namespace {
std::atomic<const char*> imageHTTPStage{"idle"};
std::atomic<uint32_t> imageHTTPBytes{0};
std::atomic<bool> imageHTTPContinue{false};
esp_netif_t* station = nullptr;
std::atomic<bool> online{false}, scanDone{false};
std::atomic<uint16_t> disconnectReason{0};
nvs_handle_t wifiStorage = 0;
wifi_setup::Credentials saved, active;
wifi_setup::JoinTracker join;
uint16_t scanOwner = noConnection;
wifi_ap_record_t networks[32]{};
uint8_t networkCount = 0;
uint32_t retryAt = 0;
QueueHandle_t httpQueue = nullptr, retryQueue = nullptr;
QueueHandle_t mediaQueue = nullptr, mediaResults = nullptr;
SemaphoreHandle_t actionMutex = nullptr;
using ActionQueue = remote_network::WorkQueue<ActionRequest, 16>;
ActionQueue* actions = nullptr;
std::string deviceDescriptor;
size_t profileLimit = 0;
int udpSocket = -1;
sockaddr_in streamTarget{};
std::string streamToken, streamBody, cachedHost;
in_addr cachedAddress{};
dial_stream::Pacer streamPacer;
uint32_t bootID = 0, streamSequence = 0;
struct StreamRequest : ActionRequest {
    char host[128]{};
    int port = 0;
    uint32_t epoch = 0;
};
using StreamQueue = remote_network::WorkQueue<StreamRequest, 8>;
StreamQueue* streamRequests = nullptr;
SemaphoreHandle_t streamMutex = nullptr;
std::atomic<uint32_t> streamEpoch{0}, streamCancelEpoch{0}, streamInterval{2000};
uint32_t nowMillis() { return uint32_t(esp_timer_get_time() / 1000); }
void event(void*, esp_event_base_t base, int32_t id, void* data) {
    if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP) online = true;
    if (base == WIFI_EVENT && id == WIFI_EVENT_STA_DISCONNECTED) {
        online = false;
        disconnectReason = static_cast<wifi_event_sta_disconnected_t*>(data)->reason;
    }
    if (base == WIFI_EVENT && id == WIFI_EVENT_SCAN_DONE) scanDone = true;
}
void startStation() {
    if (!active.ssid[0]) { join.notConfigured(); return; }
    wifi_config_t config{};
    std::memcpy(config.sta.ssid, active.ssid, std::strlen(active.ssid));
    std::memcpy(config.sta.password, active.password, std::strlen(active.password));
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA, &config));
    disconnectReason = 0;
    join.begin(nowMillis());
    esp_wifi_connect();
    retryAt = nowMillis();
}
void wifiStatus(uint16_t handle, uint16_t rejected = 0, const char* rejectedSSID = nullptr) {
    esp_netif_ip_info_t info{};
    esp_netif_get_ip_info(station, &info);
    uint8_t ip[4];
    std::memcpy(ip, &info.ip.addr, sizeof(ip));
    uint8_t bytes[wifi_setup::maxStatusBytes];
    const size_t length = wifi_setup::encodeStatus(bytes,
        rejected ? wifi_setup::State::failed : join.state(), rejected ? rejected : join.why(), ip,
        rejectedSSID ? rejectedSSID : active.ssid);
    if (handle != noConnection) notify(handle, bytes, length);
    else for (auto peer : connections()) if (peer != noConnection) notify(peer, bytes, length);
}
esp_err_t busyResponse(httpd_req_t* client) {
    httpd_resp_set_status(client, "503 Service Unavailable");
    httpd_resp_set_type(client, "application/json");
    return httpd_resp_sendstr(client, "{\"error\":\"busy\"}");
}
bool submitHTTP(HTTPRequest* request) {
    ++request->references;
    if (xQueueSend(httpQueue, &request, 0) != pdTRUE) {
        request->release();
        return false;
    }
    if (xSemaphoreTake(request->done, pdMS_TO_TICKS(5000)) != pdTRUE) {
        request->abandoned = true;
        return false;
    }
    return true;
}
esp_err_t httpHandler(httpd_req_t* client) {
    if (client->method == HTTP_GET && !std::strcmp(client->uri, "/device")) {
        httpd_resp_set_type(client, "application/json");
        return httpd_resp_send(client, deviceDescriptor.data(), deviceDescriptor.size());
    }
    const bool image = !std::strcmp(client->uri, "/images");
    if (image) httpd_resp_set_hdr(client, "Connection", "close");
    const size_t limit = image ? size_t(10 + 368 * 448 * 2) : profileLimit;
    if (client->content_len > limit) {
        httpd_resp_set_status(client, "413 Content Too Large");
        httpd_resp_set_type(client, "application/json");
        return httpd_resp_sendstr(client, "{\"error\":\"image_too_large\"}");
    }
    auto* request = new (std::nothrow) HTTPRequest;
    if (!request || !request->done) {
        delete request;
        return busyResponse(client);
    }
    request->path = client->uri;
    request->post = client->method == HTTP_POST;
    request->remove = client->method == HTTP_DELETE;
    char authorization[128]{};
    if (httpd_req_get_hdr_value_str(client, "Authorization", authorization, sizeof(authorization)) == ESP_OK &&
        !std::strncmp(authorization, "Bearer ", 7)) request->token = authorization + 7;
    if (image) {
        char header[64]{};
        imageHTTPStage = "authorizing";
        imageHTTPBytes = 0;
        imageHTTPContinue = httpd_req_get_hdr_value_str(client, "Expect", header, sizeof(header)) == ESP_OK &&
            !std::strcmp(header, "100-continue");
        if (httpd_req_get_hdr_value_str(client, "X-Image-ID", header, sizeof(header)) == ESP_OK) request->imageID = header;
        if (httpd_req_get_hdr_value_str(client, "X-Image-Name", header, sizeof(header)) == ESP_OK) request->imageName = header;
        if (httpd_req_get_hdr_value_str(client, "X-Image-Kind", header, sizeof(header)) == ESP_OK) request->imageKind = header;
        if (httpd_req_get_hdr_value_str(client, "X-Image-CRC32", header, sizeof(header)) == ESP_OK) request->imageCRC = header;
        request->authorizationOnly = true;
        if (!submitHTTP(request)) { request->release(); return busyResponse(client); }
        if (request->status != 200) {
            char status[32];
            std::snprintf(status, sizeof(status), "%d Error", request->status);
            httpd_resp_set_status(client, status);
            httpd_resp_set_type(client, "application/json");
            const esp_err_t result = httpd_resp_send(client, request->response.data(), request->response.size());
            request->release();
            httpd_sess_trigger_close(client->handle, httpd_req_to_sockfd(client));
            return result;
        }
        request->authorizationOnly = false;
        imageHTTPStage = "receiving";
    }
    request->body.resize(client->content_len);
    size_t received = 0;
    while (received < request->body.size()) {
        const int count = httpd_req_recv(client, request->body.data() + received, request->body.size() - received);
        if (count <= 0) { request->release(); return ESP_FAIL; }
        received += count;
        if (image) imageHTTPBytes = received;
    }
    if (image) imageHTTPStage = "installing";
    if (!submitHTTP(request)) {
        request->release();
        return busyResponse(client);
    }
    char status[48];
    std::snprintf(status, sizeof(status), "%d %s", request->status,
        request->status == 200 ? "OK" : request->status == 201 ? "Created" : "Error");
    httpd_resp_set_status(client, status);
    httpd_resp_set_type(client, "application/json");
    const esp_err_t result = httpd_resp_send(client, request->response.data(), request->response.size());
    if (image) imageHTTPStage = "complete";
    request->release();
    if (image) httpd_sess_trigger_close(client->handle, httpd_req_to_sockfd(client));
    return result;
}
void actionWorker(void*) {
    for (;;) {
        ActionRequest request;
        xSemaphoreTake(actionMutex, portMAX_DELAY);
        const bool available = actions->take(request);
        xSemaphoreGive(actionMutex);
        if (available) {
            esp_http_client_config_t config{};
            config.url = request.url;
            config.timeout_ms = 1000;
            config.disable_auto_redirect = true;
            auto client = esp_http_client_init(&config);
            if (client) {
                esp_http_client_set_header(client, "Content-Type", "application/json");
                if (request.token[0]) {
                    const std::string authorization = std::string("Bearer ") + request.token;
                    esp_http_client_set_header(client, "Authorization", authorization.c_str());
                }
                if (!std::strcmp(request.method, "GET")) esp_http_client_set_method(client, HTTP_METHOD_GET);
                else {
                    esp_http_client_set_method(client, HTTP_METHOD_POST);
                    esp_http_client_set_post_field(client, request.body, std::strlen(request.body));
                }
                const esp_err_t result = esp_http_client_perform(client);
                const int status = esp_http_client_get_status_code(client);
                const bool refused = result == ESP_ERR_HTTP_CONNECT && esp_http_client_get_errno(client) == ECONNREFUSED;
                if (result != ESP_OK || status < 200 || status >= 300)
                    ESP_LOGW("actions", "Action failed: %s, HTTP %d", esp_err_to_name(result), status);
                esp_http_client_cleanup(client);
                if (refused && request.relayComputer != -3) {
                    auto* retry = new (std::nothrow) ActionRequest(request);
                    if (retry && xQueueSend(retryQueue, &retry, 0) != pdTRUE) delete retry;
                }
            }
            xSemaphoreTake(actionMutex, portMAX_DELAY);
            actions->finish();
            xSemaphoreGive(actionMutex);
        }
        vTaskDelay(pdMS_TO_TICKS(2));
    }
}
void mediaWorker(void*) {
    for (;;) {
        ActionRequest* request = nullptr;
        if (xQueueReceive(mediaQueue, &request, portMAX_DELAY) != pdTRUE) continue;
        auto* result = new (std::nothrow) MediaResult;
        if (!result) { delete request; continue; }
        result->computer = request->relayComputer;
        result->profileRevision = request->profileRevision;
        result->epoch = request->mediaEpoch;
        result->startedAt = nowMillis();
        esp_http_client_config_t config{};
        config.url = request->url;
        config.timeout_ms = 1500;
        config.disable_auto_redirect = true;
        config.user_data = result;
        config.event_handler = [](esp_http_client_event_t* event) -> esp_err_t {
            auto* response = static_cast<MediaResult*>(event->user_data);
            if (event->event_id == HTTP_EVENT_ON_DATA && event->data_len > 0) {
                if (response->length + event->data_len >= sizeof(response->body)) {
                    response->overflow = true;
                    return ESP_FAIL;
                }
                std::memcpy(response->body + response->length, event->data, event->data_len);
                response->length += event->data_len;
                response->body[response->length] = 0;
            }
            return ESP_OK;
        };
        auto client = esp_http_client_init(&config);
        if (client) {
            const std::string authorization = std::string("Bearer ") + request->token;
            esp_http_client_set_header(client, "Authorization", authorization.c_str());
            esp_http_client_set_header(client, "Content-Type", "application/json");
            esp_http_client_set_method(client, HTTP_METHOD_POST);
            esp_http_client_set_post_field(client, request->body, std::strlen(request->body));
            const auto outcome = esp_http_client_perform(client);
            const int status = esp_http_client_get_status_code(client);
            result->success = outcome == ESP_OK && status == 200 && !result->overflow;
            esp_http_client_cleanup(client);
        }
        result->receivedAt = nowMillis();
        delete request;
        if (xQueueSend(mediaResults, &result, 0) != pdTRUE) delete result;
    }
}
bool resolve(const char* host, in_addr& output) {
    if (inet_pton(AF_INET, host, &output) == 1) return true;
    if (cachedHost == host) { output = cachedAddress; return true; }
    std::string name(host);
    if (name.size() > 6 && name.compare(name.size() - 6, 6, ".local") == 0) {
        name.resize(name.size() - 6);
        esp_ip4_addr_t ip{};
        if (mdns_query_a(name.c_str(), 1000, &ip) != ESP_OK) return false;
        output.s_addr = ip.addr;
    } else {
        addrinfo hints{};
        hints.ai_family = AF_INET;
        hints.ai_socktype = SOCK_DGRAM;
        addrinfo* result = nullptr;
        if (getaddrinfo(host, nullptr, &hints, &result) || !result) return false;
        output = reinterpret_cast<sockaddr_in*>(result->ai_addr)->sin_addr;
        freeaddrinfo(result);
    }
    cachedHost = host;
    cachedAddress = output;
    return true;
}
void sendDatagram() {
    char bytes[1280];
    const size_t length = dial_stream::writeDatagram(bytes, sizeof(bytes), bootID, ++streamSequence,
        streamToken.c_str(), streamBody.c_str());
    if (length && online) sendto(udpSocket, bytes, length, 0, reinterpret_cast<sockaddr*>(&streamTarget), sizeof(streamTarget));
}
void streamWorker(void*) {
    uint32_t epoch = 0;
    for (;;) {
        StreamRequest request;
        xSemaphoreTake(streamMutex, portMAX_DELAY);
        const bool pending = streamRequests->take(request);
        xSemaphoreGive(streamMutex);
        const uint32_t nextEpoch = pending ? request.epoch : streamEpoch.load();
        if (nextEpoch != epoch) {
            if (streamPacer.active() && int32_t(epoch - streamCancelEpoch.load()) >= 0) sendDatagram();
            streamPacer.reset();
            epoch = nextEpoch;
        }
        if (pending) {
            in_addr address{};
            const bool resolved = int32_t(request.epoch - streamCancelEpoch.load()) >= 0 && online && resolve(request.host, address);
            const bool cancelled = int32_t(request.epoch - streamCancelEpoch.load()) < 0;
            if (!cancelled && resolved) {
                if (streamPacer.active() && (streamTarget.sin_addr.s_addr != address.s_addr ||
                    streamTarget.sin_port != htons(request.port) || streamToken != request.token)) {
                    sendDatagram();
                    streamPacer.reset();
                }
                streamTarget.sin_family = AF_INET;
                streamTarget.sin_addr = address;
                streamTarget.sin_port = htons(request.port);
                streamToken = request.token;
                streamBody = request.body;
                streamPacer.offer();
            } else if (!cancelled) {
                enqueueAction(request, false);
            }
            xSemaphoreTake(streamMutex, portMAX_DELAY);
            streamRequests->finish();
            xSemaphoreGive(streamMutex);
        }
        streamPacer.setRate(1e6 / streamInterval.load());
        if (int32_t(epoch - streamCancelEpoch.load()) < 0) streamPacer.reset();
        if (streamPacer.poll(uint32_t(esp_timer_get_time())) != dial_stream::Pacer::Send::none) sendDatagram();
        vTaskDelay(pdMS_TO_TICKS(1));
    }
}
}
void HTTPRequest::release() { if (references.fetch_sub(1) == 1) delete this; }
void beginNetwork(const char* hostname, const std::string& descriptor, size_t maxProfileBytes) {
    deviceDescriptor = descriptor;
    profileLimit = maxProfileBytes;
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    station = esp_netif_create_default_wifi_sta();
    assert(station);
    esp_netif_set_hostname(station, hostname);
    ESP_ERROR_CHECK(esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID, event, nullptr));
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP, event, nullptr));
    wifi_init_config_t config = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&config));
    ESP_ERROR_CHECK(esp_wifi_set_storage(WIFI_STORAGE_RAM));
    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
    ESP_ERROR_CHECK(esp_wifi_start());
    if (nvs_open("papergif-wifi", NVS_READWRITE, &wifiStorage) == ESP_OK) {
        size_t size = sizeof(saved.ssid);
        nvs_get_str(wifiStorage, "ssid", saved.ssid, &size);
        size = sizeof(saved.password);
        nvs_get_str(wifiStorage, "password", saved.password, &size);
    }
    ESP_ERROR_CHECK(mdns_init());
    ESP_ERROR_CHECK(mdns_hostname_set(hostname));
    ESP_ERROR_CHECK(mdns_service_add(nullptr, "_papergif-device", "_tcp", 80, nullptr, 0));
    httpQueue = xQueueCreate(4, sizeof(HTTPRequest*));
    retryQueue = xQueueCreate(8, sizeof(ActionRequest*));
    actionMutex = xSemaphoreCreateMutex();
    void* memory = heap_caps_malloc(sizeof(ActionQueue), MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    assert(httpQueue && retryQueue && actionMutex && memory);
    actions = new (memory) ActionQueue;
    static StaticTask_t worker;
    auto* stack = static_cast<StackType_t*>(heap_caps_malloc(8192, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
    const auto task = stack ? xTaskCreateStaticPinnedToCore(actionWorker, "actions", 8192, nullptr,
        tskIDLE_PRIORITY, stack, &worker, 0) : nullptr;
    if (!task) abort();
    mediaQueue = xQueueCreate(1, sizeof(ActionRequest*));
    mediaResults = xQueueCreate(2, sizeof(MediaResult*));
    static StaticTask_t mediaTask;
    auto* mediaStack = static_cast<StackType_t*>(heap_caps_malloc(6144, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
    if (!mediaQueue || !mediaResults || !mediaStack || !xTaskCreateStaticPinnedToCore(mediaWorker,
        "media-state", 6144, nullptr, tskIDLE_PRIORITY, mediaStack, &mediaTask, 0)) abort();
    httpd_config_t serverConfig = HTTPD_DEFAULT_CONFIG();
    serverConfig.stack_size = 6144;
    serverConfig.max_uri_handlers = 10;
    serverConfig.max_open_sockets = 2;
    serverConfig.recv_wait_timeout = 3;
    serverConfig.send_wait_timeout = 3;
    serverConfig.lru_purge_enable = true;
    httpd_handle_t server = nullptr;
    ESP_ERROR_CHECK(httpd_start(&server, &serverConfig));
    for (auto path : {"/device", "/status", "/debug/inputs", "/remote", "/device/controls"}) {
        httpd_uri_t route{};
        route.uri = path;
        route.method = HTTP_GET;
        route.handler = httpHandler;
        ESP_ERROR_CHECK(httpd_register_uri_handler(server, &route));
        if (!std::strcmp(path, "/remote") || !std::strcmp(path, "/device/controls")) {
            route.method = HTTP_POST;
            ESP_ERROR_CHECK(httpd_register_uri_handler(server, &route));
        }
    }
    httpd_uri_t mediaRoute{};
    mediaRoute.uri = "/text-source/update";
    mediaRoute.method = HTTP_POST;
    mediaRoute.handler = httpHandler;
    ESP_ERROR_CHECK(httpd_register_uri_handler(server, &mediaRoute));
    httpd_uri_t imageRoute{};
    imageRoute.uri = "/images";
    imageRoute.method = HTTP_POST;
    imageRoute.handler = httpHandler;
    ESP_ERROR_CHECK(httpd_register_uri_handler(server, &imageRoute));
    imageRoute.method = HTTP_DELETE;
    ESP_ERROR_CHECK(httpd_register_uri_handler(server, &imageRoute));
    udpSocket = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (udpSocket >= 0) fcntl(udpSocket, F_SETFL, O_NONBLOCK);
    bootID = esp_random();
    streamMutex = xSemaphoreCreateMutex();
    void* streamMemory = heap_caps_malloc(sizeof(StreamQueue), MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (!streamMutex || !streamMemory) abort();
    streamRequests = new (streamMemory) StreamQueue;
    static StaticTask_t streamTask;
    auto* streamStack = static_cast<StackType_t*>(heap_caps_malloc(8192, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
    if (!streamStack || !xTaskCreateStaticPinnedToCore(streamWorker, "dial-stream", 8192, nullptr,
        tskIDLE_PRIORITY, streamStack, &streamTask, 0)) abort();
    ESP_LOGI("network", "Station only; provisioning over Bluetooth, no access point");
}
void configureNetwork(JsonDocument& profile, bool replaceSaved) {
    const char* profileSSID = profile["wifiSSID"] | "";
    const char* profilePassword = profile["wifiPassword"] | "";
    const bool useProfile = (replaceSaved || !saved.ssid[0]) &&
        wifi_setup::profileReplacesSaved(saved, profileSSID, profilePassword);
    wifi_setup::Credentials next;
    strlcpy(next.ssid, useProfile ? profileSSID : saved.ssid, sizeof(next.ssid));
    strlcpy(next.password, useProfile ? profilePassword : saved.password, sizeof(next.password));
    if (useProfile && (std::strcmp(next.ssid, saved.ssid) || std::strcmp(next.password, saved.password))) {
        if (wifiStorage && nvs_set_str(wifiStorage, "ssid", next.ssid) == ESP_OK &&
            nvs_set_str(wifiStorage, "password", next.password) == ESP_OK && nvs_commit(wifiStorage) == ESP_OK)
            saved = next;
        else ESP_LOGW("network", "Could not persist profile Wi-Fi settings");
    }
    if (online && !std::strcmp(next.ssid, active.ssid) && !std::strcmp(next.password, active.password)) return;
    active = next;
    if (scanOwner != noConnection) return;
    esp_wifi_disconnect();
    online = false;
    startStation();
}
bool connected() { return online; }
void imageHTTPDiagnostics(JsonObject json) {
    json["stage"] = imageHTTPStage.load();
    json["receivedBytes"] = imageHTTPBytes.load();
    json["expectContinue"] = imageHTTPContinue.load();
}
int signal() {
    wifi_ap_record_t record{};
    return online && esp_wifi_sta_get_ap_info(&record) == ESP_OK ? std::clamp(int(record.rssi), -100, 0) : -100;
}
std::string address() {
    esp_netif_ip_info_t info{};
    if (!online || esp_netif_get_ip_info(station, &info) != ESP_OK) return "0.0.0.0";
    char result[16];
    std::snprintf(result, sizeof(result), IPSTR, IP2STR(&info.ip));
    return result;
}
bool consumeWiFi(const BLEFrame& frame, bool allowed) {
    if (frame.kind != FrameKind::control || !frame.length) return false;
    const auto* bytes = frame.bytes;
    switch (bytes[0]) {
    case wifi_setup::scanRequest: {
        if (frame.length != 1) return true;
        if (scanOwner != noConnection) { scanOwner = frame.connection; return true; }
        if (!online) esp_wifi_disconnect();
        scanDone = false;
        scanOwner = frame.connection;
        if (esp_wifi_scan_start(nullptr, false) != ESP_OK) scanDone = true;
        return true;
    }
    case wifi_setup::networkRead: {
        if (frame.length != 2 || bytes[1] >= networkCount) {
            const uint8_t error = wifi_setup::failed;
            notify(frame.connection, &error, 1); return true;
        }
        const auto& record = networks[bytes[1]];
        uint8_t response[wifi_setup::maxNetworkBytes];
        const size_t length = wifi_setup::encodeNetwork(response, bytes[1], record.rssi,
            record.authmode != WIFI_AUTH_OPEN, reinterpret_cast<const char*>(record.ssid));
        notify(frame.connection, response, length);
        return true;
    }
    case wifi_setup::statusRequest:
        if (frame.length == 1) wifiStatus(frame.connection);
        return true;
    case wifi_setup::joinRequest: {
        wifi_setup::Credentials next;
        uint16_t error = 0;
        if (!wifi_setup::parseJoin(bytes, frame.length, next)) error = wifi_setup::reason::invalidRequest;
        else if (!allowed) error = wifi_setup::reason::unauthorized;
        else if (!wifiStorage || nvs_set_str(wifiStorage, "ssid", next.ssid) != ESP_OK ||
                 nvs_set_str(wifiStorage, "password", next.password) != ESP_OK || nvs_commit(wifiStorage) != ESP_OK)
            error = wifi_setup::reason::storageFailed;
        if (error) { wifiStatus(frame.connection, error, next.ssid); return true; }
        saved = active = next;
        esp_wifi_scan_stop();
        scanOwner = noConnection;
        esp_wifi_disconnect();
        online = false;
        startStation();
        wifiStatus(frame.connection);
        return true;
    }
    default: return false;
    }
}
bool pollNetwork() {
    if (scanOwner != noConnection && scanDone.exchange(false)) {
        uint16_t count = sizeof(networks) / sizeof(networks[0]);
        if (esp_wifi_scan_get_ap_records(&count, networks) != ESP_OK) count = 0;
        networkCount = 0;
        for (uint16_t index = 0; index < count; ++index) {
            if (!networks[index].ssid[0]) continue;
            bool duplicate = false;
            for (uint8_t known = 0; known < networkCount; ++known)
                duplicate = duplicate || !std::strcmp(reinterpret_cast<char*>(networks[index].ssid),
                                                     reinterpret_cast<char*>(networks[known].ssid));
            if (!duplicate) networks[networkCount++] = networks[index];
        }
        const uint8_t response[] = {wifi_setup::networkCount, networkCount};
        notify(scanOwner, response, sizeof(response));
        scanOwner = noConnection;
        if (!online) startStation();
    }
    if (scanOwner == noConnection && join.update(online, disconnectReason, nowMillis())) wifiStatus(noConnection);
    if (!online && active.ssid[0] && scanOwner == noConnection && nowMillis() - retryAt >= 5000) {
        retryAt = nowMillis();
        esp_wifi_connect();
    }
    static bool previouslyOnline = false;
    const bool lost = previouslyOnline && !online;
    if (lost) cachedHost.clear();
    previouslyOnline = online;
    return lost;
}
bool takeHTTP(HTTPRequest*& request) { return xQueueReceive(httpQueue, &request, 0) == pdTRUE; }
void completeHTTP(HTTPRequest* request) { xSemaphoreGive(request->done); request->release(); }
bool enqueueAction(const ActionRequest& request, bool safety) {
    xSemaphoreTake(actionMutex, portMAX_DELAY);
    if (safety) actions->clearPending();
    const bool accepted = actions->enqueue(request);
    xSemaphoreGive(actionMutex);
    return accepted;
}
void clearActions() {
    if (!actionMutex) return;
    xSemaphoreTake(actionMutex, portMAX_DELAY);
    actions->clearPending();
    xSemaphoreGive(actionMutex);
}
bool takeRelayRetry(ActionRequest*& request) { return xQueueReceive(retryQueue, &request, 0) == pdTRUE; }
bool enqueueMediaQuery(const ActionRequest& request) {
    auto* queued = new (std::nothrow) ActionRequest(request);
    if (!queued) return false;
    if (xQueueSend(mediaQueue, &queued, 0) == pdTRUE) return true;
    delete queued;
    return false;
}
bool takeMediaResult(MediaResult*& result) { return xQueueReceive(mediaResults, &result, 0) == pdTRUE; }
bool streamAction(const char* host, int port, const ActionRequest& action) {
    if (!online || udpSocket < 0 || !streamRequests || std::strlen(host) >= sizeof(StreamRequest::host)) return false;
    StreamRequest request;
    static_cast<ActionRequest&>(request) = action;
    strlcpy(request.host, host, sizeof(request.host));
    request.port = port;
    request.epoch = streamEpoch.load();
    xSemaphoreTake(streamMutex, portMAX_DELAY);
    const bool accepted = streamRequests->enqueue(request);
    xSemaphoreGive(streamMutex);
    return accepted;
}
void pollStream(double rate) {
    streamInterval.store(dial_stream::intervalMicros(rate));
}
void flushStream(bool sendFinal) {
    const uint32_t next = streamEpoch.fetch_add(1) + 1;
    if (!sendFinal) streamCancelEpoch.store(next);
}
}