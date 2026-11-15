#pragma once

#include "wifi_setup.h"
#include "bluetooth.h"
#include <ArduinoJson.h>
#include <atomic>
#include <string>
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"

namespace native_device {
struct ActionRequest {
    char url[256]{}, body[1024]{}, token[80]{}, method[5] = "POST", controlId[80]{};
    bool slider = false;
    uint32_t profileRevision = 0;
    uint32_t mediaEpoch = 0;
    int8_t relayComputer = -3;
};
struct MediaResult {
    int8_t computer = -3;
    uint32_t profileRevision = 0, epoch = 0, startedAt = 0, receivedAt = 0;
    bool success = false, overflow = false;
    size_t length = 0;
    char body[1536]{};
};
struct HTTPRequest {
    std::string path, body, token, response;
    std::string imageID, imageName, imageKind, imageCRC;
    bool post = false;
    bool remove = false, authorizationOnly = false;
    int status = 200;
    SemaphoreHandle_t done = xSemaphoreCreateBinary();
    std::atomic<unsigned> references{1};
    std::atomic<bool> abandoned{false};
    void release();
    ~HTTPRequest() { if (done) vSemaphoreDelete(done); }
};
void beginNetwork(const char* hostname, const std::string& descriptor, size_t maxProfileBytes);
void configureNetwork(JsonDocument& profile, bool replaceSaved);
bool pollNetwork();
bool connected();
int signal();
std::string address();
void imageHTTPDiagnostics(JsonObject json);
bool consumeWiFi(const BLEFrame& frame, bool allowed);
bool takeHTTP(HTTPRequest*& request);
void completeHTTP(HTTPRequest* request);
bool enqueueAction(const ActionRequest& request, bool safety);
void clearActions();
bool takeRelayRetry(ActionRequest*& request);
bool enqueueMediaQuery(const ActionRequest& request);
bool takeMediaResult(MediaResult*& result);
bool streamAction(const char* host, int port, const ActionRequest& action);
void pollStream(double rate);
void flushStream(bool sendFinal = true);
}