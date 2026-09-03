#include <Arduino.h>
#include <ArduinoJson.h>
#include <errno.h>
#include <ESPmDNS.h>
#include <M5Unified.h>
#include <NimBLEDevice.h>
#include <SD.h>
#include <SPI.h>
#include <WebServer.h>
#include <WiFi.h>
#include <esp_heap_caps.h>
#include <nvs.h>
#include <esp_sleep.h>
#include <esp_system.h>

namespace {

constexpr char kServiceUuid[] = "7A230001-7D2A-4C7B-9C42-504749460001";
constexpr char kControlUuid[] = "7A230002-7D2A-4C7B-9C42-504749460001";
constexpr char kDataUuid[] = "7A230003-7D2A-4C7B-9C42-504749460001";

constexpr char kAnimationPath[] = "/animation.pgif";
constexpr char kTemporaryPath[] = "/animation.tmp";
constexpr char kBackupPath[] = "/animation.bak";
constexpr char kLibraryDirectory[] = "/library";
constexpr char kActivePath[] = "/library/active.txt";
constexpr char kSettingsPath[] = "/library/settings.bin";
constexpr char kRemoteProfilePath[] = "/library/remote.json";
constexpr char kRemoteProfileTemporaryPath[] = "/library/remote.tmp";
constexpr char kWifiPassword[] = "paperdisplay";

constexpr uint8_t kBeginUpload = 0x10;
constexpr uint8_t kUploadReady = 0x11;
constexpr uint8_t kFinishUpload = 0x12;
constexpr uint8_t kUploadComplete = 0x13;
constexpr uint8_t kUploadDataReceived = 0x14;
constexpr uint8_t kUploadProgress = 0x15;
constexpr uint8_t kListLibrary = 0x20;
constexpr uint8_t kLibraryCount = 0x21;
constexpr uint8_t kReadLibraryItem = 0x22;
constexpr uint8_t kDeleteLibraryItem = 0x23;
constexpr uint8_t kLibraryItemDeleted = 0x24;
constexpr uint8_t kSelectLibraryItem = 0x25;
constexpr uint8_t kStartWifi = 0x30;
constexpr uint8_t kWifiInfo = 0x31;
constexpr uint8_t kWifiFailed = 0x32;
constexpr uint8_t kScanWifiNetworks = 0x33;
constexpr uint8_t kWifiNetworkCount = 0x34;
constexpr uint8_t kReadWifiNetwork = 0x35;
constexpr uint8_t kHomeWifiStatus = 0x36;
constexpr uint8_t kRequestHomeWifiStatus = 0x37;
constexpr uint8_t kPrepareWifiUpload = 0x38;
constexpr uint8_t kBeginRemoteProfile = 0x40;
constexpr uint8_t kRemoteProfileReady = 0x41;
constexpr uint8_t kFinishRemoteProfile = 0x42;
constexpr uint8_t kRemoteProfileComplete = 0x43;
constexpr uint8_t kRemoteProfileDataReceived = 0x44;
constexpr uint8_t kRemoteProfileProgress = 0x45;
constexpr uint8_t kUploadFailed = 0x7F;

constexpr uint16_t kDisplayWidth = 540;
constexpr uint16_t kDisplayHeight = 960;
constexpr uint32_t kFrameBytesPerRow = (kDisplayWidth + 7) / 8;
constexpr uint32_t kFrameBytes = kFrameBytesPerRow * kDisplayHeight;
constexpr uint32_t kGrayscaleFrameBytesPerRow = (kDisplayWidth + 1) / 2;
constexpr uint32_t kGrayscaleFrameBytes = kGrayscaleFrameBytesPerRow * kDisplayHeight;
constexpr uint32_t kLegacyFrameBytes = kDisplayWidth * kDisplayHeight / 8;
constexpr uint32_t kHeaderBytes = 22;
constexpr uint32_t kUploadWindowBytes = 16 * 1024;
constexpr size_t kWifiWriteBufferBytes = 32 * 1024;
constexpr uint8_t kHomeWifiAuthenticationAttemptLimit = 3;
constexpr uint32_t kHomeWifiAuthenticationRetryDelayMs = 1500;
constexpr uint32_t kSlideshowIntervalsSeconds[] = {
    10, 30, 60, 120, 300, 600, 900, 1800, 3600,
};
constexpr size_t kSlideshowIntervalCount =
    sizeof(kSlideshowIntervalsSeconds) / sizeof(kSlideshowIntervalsSeconds[0]);
constexpr uint8_t kDefaultSlideshowIntervalIndex = 2;
constexpr uint8_t kUseProfileScreensaverDelay = 0xFF;
constexpr lgfx::bgr888_t kGrayscalePalette[] = {
    {0, 0, 0},
    {17, 17, 17},
    {34, 34, 34},
    {51, 51, 51},
    {68, 68, 68},
    {85, 85, 85},
    {102, 102, 102},
    {119, 119, 119},
    {136, 136, 136},
    {153, 153, 153},
    {170, 170, 170},
    {187, 187, 187},
    {204, 204, 204},
    {221, 221, 221},
    {238, 238, 238},
    {255, 255, 255},
};
constexpr size_t kMaximumLibraryItems = 128;
constexpr size_t kMaximumTitleBytes = 48;
constexpr size_t kMaximumPathBytes = 40;
constexpr size_t kLibraryRowsPerPage = 7;
constexpr size_t kMaximumRemotePages = 8;
constexpr size_t kMaximumRemoteControls = 16;
constexpr size_t kMaximumRemoteComputers = 8;
constexpr size_t kRemoteIconDimension = 64;
constexpr size_t kRemoteIconBytes = kRemoteIconDimension * kRemoteIconDimension / 8;
constexpr size_t kMaximumRemoteProfileBytes = 256 * 1024;
constexpr size_t kMaximumPersistedSliders =
    kMaximumRemotePages * kMaximumRemoteControls;
constexpr char kNvsNamespace[] = "papergif";
constexpr char kSliderPositionsKey[] = "sliderPos";
constexpr uint32_t kSliderPositionsMagic = 0x534C4452;
constexpr char kToggleStatesKey[] = "toggleState";
constexpr uint32_t kToggleStatesMagic = 0x54474C45;
constexpr int32_t kLibraryRowTop = 166;
constexpr int32_t kLibraryRowHeight = 88;
constexpr uint32_t kRenderMarker = 0x50474946;

constexpr int kSdSclk = 14;
constexpr int kSdMiso = 13;
constexpr int kSdMosi = 12;
constexpr int kSdCs = 4;
constexpr int kPreviousButtonPin = 37;
constexpr int kMenuButtonPin = 38;
constexpr int kNextButtonPin = 39;

struct AnimationHeader {
    uint16_t frameCount = 0;
    uint16_t scanRateHz = 0;
    uint8_t transitionScans = 0;
    bool adaptiveCleaning = false;
    uint16_t cleanRefreshInterval = 0;
    uint32_t frameBytes = 0;
    uint32_t framesOffset = 0;
    bool grayscale = false;
};

struct UploadState {
    File file;
    uint32_t expectedBytes = 0;
    uint32_t expectedCrc = 0;
    uint32_t receivedBytes = 0;
    uint32_t nextAcknowledgementAt = kUploadWindowBytes;
    uint32_t runningCrc = UINT32_MAX;
    uint32_t lastActivityAt = 0;
    char destinationPath[kMaximumPathBytes] = {};
    char title[kMaximumTitleBytes + 1] = {};
    bool active = false;
};

struct RemoteProfileUploadState {
    File file;
    uint32_t expectedBytes = 0;
    uint32_t expectedCrc = 0;
    uint32_t receivedBytes = 0;
    uint32_t nextAcknowledgementAt = kUploadWindowBytes;
    uint32_t runningCrc = UINT32_MAX;
    uint32_t lastActivityAt = 0;
    bool active = false;
    bool finishRequested = false;
};

struct RemoteAction {
    char type[24] = {};
    char host[64] = {};
    char text[192] = {};
    int value = 0;
    char modifiers[4][12] = {};
    uint8_t modifierCount = 0;
    char computerId[40] = {};
};

struct RemoteComputer {
    char id[40] = {};
    char name[32] = {};
    char host[64] = {};
    uint16_t port = 43821;
    char token[80] = {};
};

struct RemoteControl {
    char id[40] = {};
    char title[32] = {};
    char symbol[32] = {};
    uint8_t iconBitmap[kRemoteIconBytes] = {};
    uint8_t iconDimension = 0;
    bool hasIconBitmap = false;
    uint8_t kind = 0;
    bool slider = false;
    bool toggle = false;
    bool toggleOn = false;
    int8_t layoutSlot = -1;
    uint8_t gridWidth = 1;
    uint8_t gridHeight = 1;
    char textSource[20] = {};
    char sourceText[193] = {};
    char referencedControlId[40] = {};
    char textComputerId[40] = {};
    char dateFormat[40] = {};
    char placeholder[65] = {};
    char resolvedText[193] = {};
    bool hasResolvedValue = false;
    uint8_t textSize = 4;
    uint8_t textHorizontalAlignment = 0;
    uint8_t textVerticalAlignment = 0;
    uint8_t tapBehavior = 0;
    uint32_t refreshIntervalMs = 0;
    uint32_t nextRefreshAt = 0;
    RemoteAction action;
};

struct RemotePage {
    char id[40] = {};
    char name[32] = {};
    RemoteControl controls[kMaximumRemoteControls];
    uint8_t controlCount = 0;
};

struct RemoteProfile {
    char wifiSsid[33] = {};
    char wifiPassword[65] = {};
    char macHost[64] = {};
    uint16_t macPort = 43821;
    char macToken[80] = {};
    RemoteComputer computers[kMaximumRemoteComputers];
    uint8_t computerCount = 0;
    uint32_t screensaverDelayMs = 30000;
    int16_t timeZoneOffsetMinutes = 0;
    m5::rtc_datetime_t deviceClock;
    bool hasDeviceClock = false;
    RemotePage pages[kMaximumRemotePages];
    uint8_t pageCount = 0;
    bool configured = false;
};

struct PersistedSliderPosition {
    char controlId[40] = {};
    uint8_t value = 0;
};

struct SliderPositionStore {
    uint32_t magic = kSliderPositionsMagic;
    uint8_t version = 1;
    uint8_t count = 0;
    uint16_t reserved = 0;
    PersistedSliderPosition positions[kMaximumPersistedSliders];
};

struct ToggleStateStore {
    uint32_t magic = kToggleStatesMagic;
    uint8_t version = 1;
    uint8_t count = 0;
    uint16_t reserved = 0;
    uint64_t controlIdHashes[kMaximumPersistedSliders] = {};
    uint8_t states[kMaximumPersistedSliders] = {};
};

struct LibraryItem {
    char path[kMaximumPathBytes] = {};
    char title[kMaximumTitleBytes + 1] = {};
    uint16_t frameCount = 0;
};

NimBLECharacteristic* controlCharacteristic = nullptr;
WebServer wifiServer(80);
UploadState upload;
RemoteProfileUploadState remoteProfileUpload;
RemoteProfile* remoteProfile = nullptr;
RemoteProfile* pendingRemoteProfile = nullptr;
SliderPositionStore sliderPositionStore;
bool sliderPositionStoreLoaded = false;
ToggleStateStore toggleStateStore;
bool toggleStateStoreLoaded = false;
File animationFile;
AnimationHeader animationHeader;
uint16_t* frameDurations = nullptr;
uint8_t* frameBuffer = nullptr;
uint8_t* previousFrameBuffer = nullptr;
bool previousFrameValid = false;
uint16_t currentFrame = 0;
uint32_t nextFrameAt = 0;
uint32_t displayedFrames = 0;
bool animationReady = false;
bool sdReady = false;
bool stillFrameDisplayed = false;
volatile bool deviceConnected = false;
volatile bool splashPending = true;
uint8_t displayedUploadProgress = UINT8_MAX;
volatile uint8_t pendingUploadProgress = 0;
uint32_t lastProgressDisplayAt = 0;
bool finishRequested = false;
volatile bool uploadScreenPending = false;
LibraryItem libraryItems[kMaximumLibraryItems];
size_t libraryItemCount = 0;
size_t libraryPage = 0;
size_t librarySelection = 0;
bool libraryVisible = false;
bool settingsVisible = false;
bool slideshowMenuVisible = false;
bool wifiActive = false;
volatile bool wifiApStarted = false;
volatile bool wifiApStopping = false;
bool wifiModeVisible = false;
bool wifiServerConfigured = false;
bool wifiServerRunning = false;
bool mdnsRunning = false;
bool wifiUploadSucceeded = false;
bool wifiUploadFailed = false;
bool wifiUploadRequestAccepted = false;
bool wifiUploadRequestFinal = false;
uint32_t wifiUploadRequestOffset = 0;
uint32_t wifiUploadExpectedChunkBytes = 0;
bool wifiScreenRefreshPending = false;
volatile bool wifiStartRequested = false;
uint32_t wifiStartRequestedAt = 0;
volatile bool wifiScanRequested = false;
int16_t wifiScanResultCount = 0;
volatile bool wifiStopRequested = false;
uint32_t wifiStopRequestedAt = 0;
bool bluetoothActive = false;
bool bluetoothStopping = false;
volatile bool bluetoothSuspendRequested = false;
volatile bool bluetoothResumeRequested = false;
bool bluetoothSuspendedForWifiUpload = false;
uint32_t bluetoothSuspendRequestedAt = 0;
uint32_t bluetoothSuspendedAt = 0;
bool slideshowEnabled = false;
bool slideshowDeepSleep = false;
bool deepSleepSuspended = false;
uint8_t slideshowIntervalIndex = kDefaultSlideshowIntervalIndex;
uint8_t screensaverDelayIndex = kUseProfileScreensaverDelay;
uint32_t nextSlideshowAt = 0;
esp_sleep_wakeup_cause_t wakeupCause = ESP_SLEEP_WAKEUP_UNDEFINED;
bool recoveredFromRenderCrash = false;
bool remoteVisible = false;
bool screensaverActive = false;
volatile bool touchInterruptPending = false;
int8_t activeRemoteControlIndex = -1;
uint8_t activeRemoteTouchPage = 0;
bool activeRemoteControlVisual = false;
bool activeRemoteHoldTriggered = false;
uint32_t activeRemoteTouchStartedAt = 0;
uint32_t activeRemoteLastRepeatAt = 0;
uint32_t activeRemoteSliderRenderedAt = 0;
uint32_t activeRemoteSliderSentAt = 0;
int16_t activeRemoteSliderSentValue = -1;
bool homeWifiConnecting = false;
volatile bool homeWifiAuthenticationRetryPending = false;
volatile bool homeWifiStatusChanged = false;
volatile bool homeWifiNotificationPending = false;
volatile uint8_t homeWifiState = 0;
volatile uint8_t homeWifiAuthenticationFailures = 0;
volatile uint16_t homeWifiFailureReason = 0;
uint64_t homeWifiSessionToken = 0;
uint8_t remotePageIndex = 0;
uint32_t lastRemoteActivityAt = 0;
char remoteActionStatus[40] = {};
uint32_t remoteActionStatusClearAt = 0;
uint32_t homeWifiAttemptedAt = 0;
volatile uint32_t homeWifiAuthenticationRetryRequestedAt = 0;
int8_t remoteBatteryLevel = -1;
uint32_t remoteBatterySampledAt = 0;
char activeAnimationPath[kMaximumPathBytes] = "/animation.pgif";
char wifiSsid[24] = {};
uint8_t wifiWriteBuffer[kWifiWriteBufferBytes];
size_t wifiWriteBufferLength = 0;
uint32_t wifiUploadStartedAt = 0;
RTC_DATA_ATTR volatile uint32_t renderInProgress = 0;

void displayUploadStart();
void displayUploadProgress(uint8_t progress);
void completeUpload();
void displayLibrary();
void displaySettings();
void displaySlideshowMenu();
void displayWifiMode();
void refreshLibrary();
void displayCurrentFrame();
void selectLibraryItem(size_t index);
void persistActiveSelection();
void showLibrary();
void closeWifiMode();
void prepareRemoteTextBoxes();
void pollRemoteTextBoxes();
bool isMacTextSource(const RemoteControl& control);
bool postJsonResponse(
    const String& url,
    const String& body,
    String& responseBody,
    const char* token);
void stopWifiMode();
void startBluetooth();
void suspendBluetoothForWifiUpload();
void resumeBluetoothAfterWifiUpload();
void displayRemote();
void displayRemoteProfileChanges(const RemoteProfile& previousProfile, uint8_t previousPageIndex);
void redrawRemoteTextBox(RemotePage& page, uint8_t controlIndex);
void connectHomeWifi();

void loadSliderPositionStore() {
    if (sliderPositionStoreLoaded) {
        return;
    }
    sliderPositionStoreLoaded = true;
    nvs_handle_t handle;
    if (nvs_open(kNvsNamespace, NVS_READONLY, &handle) != ESP_OK) {
        return;
    }
    SliderPositionStore stored;
    size_t length = sizeof(stored);
    const esp_err_t result = nvs_get_blob(handle, kSliderPositionsKey, &stored, &length);
    nvs_close(handle);
    if (result == ESP_OK && length == sizeof(stored) &&
        stored.magic == kSliderPositionsMagic && stored.version == 1 &&
        stored.count <= kMaximumPersistedSliders) {
        sliderPositionStore = stored;
    }
}

void restoreRemoteSliderPositions(RemoteProfile& profile) {
    loadSliderPositionStore();
    for (uint8_t pageIndex = 0; pageIndex < profile.pageCount; ++pageIndex) {
        RemotePage& page = profile.pages[pageIndex];
        for (uint8_t controlIndex = 0; controlIndex < page.controlCount; ++controlIndex) {
            RemoteControl& control = page.controls[controlIndex];
            if (!control.slider || control.id[0] == '\0') {
                continue;
            }
            for (uint8_t index = 0; index < sliderPositionStore.count; ++index) {
                if (strcmp(sliderPositionStore.positions[index].controlId, control.id) == 0) {
                    control.action.value = sliderPositionStore.positions[index].value;
                    break;
                }
            }
        }
    }
}

void persistRemoteSliderPositions(const RemoteProfile& profile) {
    SliderPositionStore updated;
    for (uint8_t pageIndex = 0; pageIndex < profile.pageCount; ++pageIndex) {
        const RemotePage& page = profile.pages[pageIndex];
        for (uint8_t controlIndex = 0; controlIndex < page.controlCount; ++controlIndex) {
            const RemoteControl& control = page.controls[controlIndex];
            if (!control.slider || control.id[0] == '\0' ||
                updated.count >= kMaximumPersistedSliders) {
                continue;
            }
            PersistedSliderPosition& position = updated.positions[updated.count++];
            strlcpy(position.controlId, control.id, sizeof(position.controlId));
            position.value = constrain(control.action.value, 0, 255);
        }
    }
    loadSliderPositionStore();
    if (memcmp(&updated, &sliderPositionStore, sizeof(updated)) == 0) {
        return;
    }
    nvs_handle_t handle;
    if (nvs_open(kNvsNamespace, NVS_READWRITE, &handle) != ESP_OK) {
        Serial.println("Slider position NVS open failed");
        return;
    }
    const esp_err_t writeResult = nvs_set_blob(
        handle, kSliderPositionsKey, &updated, sizeof(updated));
    const esp_err_t commitResult = writeResult == ESP_OK ? nvs_commit(handle) : writeResult;
    nvs_close(handle);
    if (writeResult == ESP_OK && commitResult == ESP_OK) {
        sliderPositionStore = updated;
    } else {
        Serial.printf("Slider position NVS write failed: %d\n", commitResult);
    }
}

void loadToggleStateStore() {
    if (toggleStateStoreLoaded) {
        return;
    }
    toggleStateStoreLoaded = true;
    nvs_handle_t handle;
    if (nvs_open(kNvsNamespace, NVS_READONLY, &handle) != ESP_OK) {
        return;
    }
    ToggleStateStore stored;
    size_t length = sizeof(stored);
    const esp_err_t result = nvs_get_blob(handle, kToggleStatesKey, &stored, &length);
    nvs_close(handle);
    if (result == ESP_OK && length == sizeof(stored) &&
        stored.magic == kToggleStatesMagic && stored.version == 1 &&
        stored.count <= kMaximumPersistedSliders) {
        toggleStateStore = stored;
    }
}

uint64_t remoteControlIdHash(const char* controlId) {
    uint64_t hash = 1469598103934665603ULL;
    while (*controlId != '\0') {
        hash ^= static_cast<uint8_t>(*controlId++);
        hash *= 1099511628211ULL;
    }
    return hash;
}

void restoreRemoteToggleStates(RemoteProfile& profile) {
    loadToggleStateStore();
    for (uint8_t pageIndex = 0; pageIndex < profile.pageCount; ++pageIndex) {
        RemotePage& page = profile.pages[pageIndex];
        for (uint8_t controlIndex = 0; controlIndex < page.controlCount; ++controlIndex) {
            RemoteControl& control = page.controls[controlIndex];
            if (!control.toggle || control.id[0] == '\0') {
                continue;
            }
            const uint64_t controlIdHash = remoteControlIdHash(control.id);
            for (uint8_t index = 0; index < toggleStateStore.count; ++index) {
                if (toggleStateStore.controlIdHashes[index] == controlIdHash) {
                    control.toggleOn = toggleStateStore.states[index] != 0;
                    break;
                }
            }
        }
    }
}

void persistRemoteToggleStates(const RemoteProfile& profile) {
    ToggleStateStore updated;
    for (uint8_t pageIndex = 0; pageIndex < profile.pageCount; ++pageIndex) {
        const RemotePage& page = profile.pages[pageIndex];
        for (uint8_t controlIndex = 0; controlIndex < page.controlCount; ++controlIndex) {
            const RemoteControl& control = page.controls[controlIndex];
            if (!control.toggle || control.id[0] == '\0' ||
                updated.count >= kMaximumPersistedSliders) {
                continue;
            }
            const uint8_t index = updated.count++;
            updated.controlIdHashes[index] = remoteControlIdHash(control.id);
            updated.states[index] = control.toggleOn ? 1 : 0;
        }
    }
    loadToggleStateStore();
    if (memcmp(&updated, &toggleStateStore, sizeof(updated)) == 0) {
        return;
    }
    nvs_handle_t handle;
    if (nvs_open(kNvsNamespace, NVS_READWRITE, &handle) != ESP_OK) {
        Serial.println("Toggle state NVS open failed");
        return;
    }
    const esp_err_t writeResult = nvs_set_blob(
        handle, kToggleStatesKey, &updated, sizeof(updated));
    const esp_err_t commitResult = writeResult == ESP_OK ? nvs_commit(handle) : writeResult;
    nvs_close(handle);
    if (writeResult == ESP_OK && commitResult == ESP_OK) {
        toggleStateStore = updated;
    } else {
        Serial.printf("Toggle state NVS write failed: %d\n", commitResult);
    }
}

void prepareWifiSsid() {
    if (wifiSsid[0] != '\0') {
        return;
    }
    const uint16_t suffix = static_cast<uint16_t>(ESP.getEfuseMac());
    snprintf(wifiSsid, sizeof(wifiSsid), "paperGIF-%04X", suffix);
}

void appendJsonString(String& json, const char* value) {
    json += '"';
    while (*value != '\0') {
        const char character = *value++;
        if (character == '"' || character == '\\') {
            json += '\\';
        }
        if (static_cast<uint8_t>(character) >= 0x20) {
            json += character;
        }
    }
    json += '"';
}

bool wifiRequestFromAccessPoint() {
    return wifiActive && wifiServer.client().localIP() == WiFi.softAPIP();
}

bool wifiRequestAuthorized() {
    if (wifiRequestFromAccessPoint()) {
        return true;
    }
    const String authorization = wifiServer.header("Authorization");
    constexpr char bearerPrefix[] = "Bearer ";
    if (!authorization.startsWith(bearerPrefix)) {
        return false;
    }
    const String token = authorization.substring(sizeof(bearerPrefix) - 1);
    char sessionToken[17];
    snprintf(sessionToken, sizeof(sessionToken), "%08lX%08lX",
        static_cast<unsigned long>(homeWifiSessionToken >> 32),
        static_cast<unsigned long>(homeWifiSessionToken));
    if (homeWifiSessionToken != 0 && token == sessionToken) {
        return true;
    }
    if (remoteProfile == nullptr) {
        return false;
    }
    if (remoteProfile->macToken[0] != '\0' && token == remoteProfile->macToken) {
        return true;
    }
    for (uint8_t index = 0; index < remoteProfile->computerCount; ++index) {
        if (remoteProfile->computers[index].token[0] != '\0' &&
            token == remoteProfile->computers[index].token) {
            return true;
        }
    }
    return false;
}

uint32_t slideshowIntervalSeconds() {
    return kSlideshowIntervalsSeconds[slideshowIntervalIndex];
}

uint32_t screensaverDelaySeconds() {
    if (screensaverDelayIndex < kSlideshowIntervalCount) {
        return kSlideshowIntervalsSeconds[screensaverDelayIndex];
    }
    if (remoteProfile != nullptr) {
        return max<uint32_t>(10, remoteProfile->screensaverDelayMs / 1000);
    }
    return 30;
}

uint32_t screensaverDelayMs() {
    return screensaverDelaySeconds() * 1000;
}

uint32_t slideshowIntervalMs() {
    return slideshowIntervalSeconds() * 1000;
}

uint64_t slideshowIntervalUs() {
    return static_cast<uint64_t>(slideshowIntervalSeconds()) * 1000000ULL;
}

void persistSettings() {
    SD.remove(kSettingsPath);
    File file = SD.open(kSettingsPath, FILE_WRITE);
    if (file) {
        file.write(slideshowEnabled ? 1 : 0);
        file.write(slideshowDeepSleep ? 1 : 0);
        file.write(slideshowIntervalIndex);
        file.write(screensaverDelayIndex);
        file.close();
    }
}

void restoreSettings() {
    File file = SD.open(kSettingsPath, FILE_READ);
    if (!file) {
        return;
    }
    const int enabled = file.read();
    const int deepSleep = file.read();
    const int intervalIndex = file.read();
    const int delayIndex = file.read();
    file.close();
    slideshowEnabled = enabled == 1;
    slideshowDeepSleep = deepSleep == 1;
    if (intervalIndex >= 0 && intervalIndex < kSlideshowIntervalCount) {
        slideshowIntervalIndex = static_cast<uint8_t>(intervalIndex);
    }
    if (delayIndex >= 0 && delayIndex < kSlideshowIntervalCount) {
        screensaverDelayIndex = static_cast<uint8_t>(delayIndex);
    }
}

int8_t remoteIconHexValue(char character) {
    if (character >= '0' && character <= '9') {
        return character - '0';
    }
    if (character >= 'A' && character <= 'F') {
        return character - 'A' + 10;
    }
    if (character >= 'a' && character <= 'f') {
        return character - 'a' + 10;
    }
    return -1;
}

uint8_t parseRemoteIconBitmap(const char* hex, uint8_t* bitmap) {
    if (hex == nullptr) {
        return 0;
    }
    const size_t hexLength = strlen(hex);
    const uint8_t dimension = hexLength == 256 ? 32 : hexLength == 1024 ? 64 : 0;
    if (dimension == 0) {
        return 0;
    }
    memset(bitmap, 0, kRemoteIconBytes);
    const size_t byteCount = dimension * dimension / 8;
    for (size_t index = 0; index < byteCount; ++index) {
        const int8_t high = remoteIconHexValue(hex[index * 2]);
        const int8_t low = remoteIconHexValue(hex[index * 2 + 1]);
        if (high < 0 || low < 0) {
            memset(bitmap, 0, kRemoteIconBytes);
            return 0;
        }
        bitmap[index] = static_cast<uint8_t>((high << 4) | low);
    }
    return dimension;
}

bool parseRemoteProfile(const char* path, RemoteProfile& output) {
    memset(&output, 0, sizeof(output));
    File file = SD.open(path, FILE_READ);
    if (!file) {
        return false;
    }
    JsonDocument document;
    const DeserializationError error = deserializeJson(document, file);
    file.close();
    const int profileVersion = document["version"] | 1;
    if (error || profileVersion < 1 || profileVersion > 2) {
        Serial.printf("Remote profile parse failed: %s\n", error ? error.c_str() : "version");
        return false;
    }

    strlcpy(output.wifiSsid, document["wifiSSID"] | "", sizeof(output.wifiSsid));
    strlcpy(output.wifiPassword, document["wifiPassword"] | "", sizeof(output.wifiPassword));
    strlcpy(output.macHost, document["macHost"] | "", sizeof(output.macHost));
    output.macPort = constrain(document["macPort"] | 43821, 1, 65535);
    strlcpy(output.macToken, document["macToken"] | "", sizeof(output.macToken));
    for (JsonObject computerJson : document["computers"].as<JsonArray>()) {
        if (output.computerCount >= kMaximumRemoteComputers) {
            break;
        }
        RemoteComputer& computer = output.computers[output.computerCount];
        strlcpy(computer.id, computerJson["id"] | "", sizeof(computer.id));
        strlcpy(computer.name, computerJson["name"] | "Computer", sizeof(computer.name));
        strlcpy(computer.host, computerJson["host"] | "", sizeof(computer.host));
        computer.port = constrain(computerJson["port"] | 43821, 1, 65535);
        strlcpy(computer.token, computerJson["token"] | "", sizeof(computer.token));
        if (computer.id[0] != '\0' && computer.host[0] != '\0' && computer.token[0] != '\0') {
            ++output.computerCount;
        }
    }
    const uint32_t delaySeconds = constrain(
        document["screensaverDelaySeconds"] | 30, 10, 3600);
    output.screensaverDelayMs = delaySeconds * 1000;
    output.timeZoneOffsetMinutes = constrain(
        document["timeZoneOffsetMinutes"] | 0, -14 * 60, 14 * 60);
    JsonObject clockJson = document["deviceClock"];
    const int clockYear = clockJson["year"] | 0;
    const int clockMonth = clockJson["month"] | 0;
    const int clockDay = clockJson["day"] | 0;
    const int clockWeekday = clockJson["weekday"] | -1;
    const int clockHour = clockJson["hour"] | -1;
    const int clockMinute = clockJson["minute"] | -1;
    const int clockSecond = clockJson["second"] | -1;
    output.hasDeviceClock = clockYear >= 2020 && clockYear <= 2099 &&
        clockMonth >= 1 && clockMonth <= 12 && clockDay >= 1 && clockDay <= 31 &&
        clockWeekday >= 0 && clockWeekday <= 6 && clockHour >= 0 && clockHour <= 23 &&
        clockMinute >= 0 && clockMinute <= 59 && clockSecond >= 0 && clockSecond <= 59;
    if (output.hasDeviceClock) {
        output.deviceClock = {
            {
                static_cast<int16_t>(clockYear),
                static_cast<int8_t>(clockMonth),
                static_cast<int8_t>(clockDay),
                static_cast<int8_t>(clockWeekday),
            },
            {
                static_cast<int8_t>(clockHour),
                static_cast<int8_t>(clockMinute),
                static_cast<int8_t>(clockSecond),
            },
        };
    }

    for (JsonObject pageJson : document["pages"].as<JsonArray>()) {
        if (output.pageCount >= kMaximumRemotePages) {
            break;
        }
        RemotePage& page = output.pages[output.pageCount];
        strlcpy(page.id, pageJson["id"] | "", sizeof(page.id));
        strlcpy(page.name, pageJson["name"] | "Remote", sizeof(page.name));
        for (JsonObject controlJson : pageJson["controls"].as<JsonArray>()) {
            if (page.controlCount >= kMaximumRemoteControls) {
                break;
            }
            RemoteControl& control = page.controls[page.controlCount];
            strlcpy(control.id, controlJson["id"] | "", sizeof(control.id));
            strlcpy(control.title, controlJson["title"] | "Control", sizeof(control.title));
            strlcpy(control.symbol, controlJson["symbol"] | "", sizeof(control.symbol));
            control.iconDimension = parseRemoteIconBitmap(
                controlJson["iconBitmap"] | static_cast<const char*>(nullptr),
                control.iconBitmap);
            control.hasIconBitmap = control.iconDimension != 0;
            const char* kind = controlJson["kind"] | "button";
            control.kind = strcmp(kind, "slider") == 0 ? 1 : strcmp(kind, "textBox") == 0 ? 2 : 0;
            control.slider = control.kind == 1;
            control.toggle = control.kind == 0 && (controlJson["isToggle"] | false);
            control.layoutSlot = constrain(controlJson["layoutSlot"] | -1, -1, 15);
            if (control.kind == 2) {
                JsonObject textBoxJson = controlJson["textBox"];
                control.gridWidth = constrain(textBoxJson["gridWidth"] | 2, 1, 2);
                control.gridHeight = constrain(textBoxJson["gridHeight"] | 1, 1, 8);
                strlcpy(control.textSource, textBoxJson["source"] | "staticText", sizeof(control.textSource));
                strlcpy(control.sourceText, textBoxJson["sourceText"] | "Text", sizeof(control.sourceText));
                strlcpy(control.referencedControlId,
                    textBoxJson["referencedControlID"] | "", sizeof(control.referencedControlId));
                strlcpy(control.textComputerId,
                    textBoxJson["computerID"] | "", sizeof(control.textComputerId));
                strlcpy(control.dateFormat, textBoxJson["dateFormat"] | "%b %e, %H:%M", sizeof(control.dateFormat));
                strlcpy(control.placeholder, textBoxJson["placeholder"] | "Unavailable", sizeof(control.placeholder));
                strlcpy(control.resolvedText,
                    strcmp(control.textSource, "staticText") == 0 ? control.sourceText : control.placeholder,
                    sizeof(control.resolvedText));
                const char* textSize = textBoxJson["textSize"] | "autoFit";
                control.textSize = strcmp(textSize, "small") == 0 ? 0
                    : strcmp(textSize, "medium") == 0 ? 1
                    : strcmp(textSize, "large") == 0 ? 2
                    : strcmp(textSize, "extraLarge") == 0 ? 3 : 4;
                const char* horizontalAlignment = textBoxJson["horizontalAlignment"] | "leading";
                control.textHorizontalAlignment = strcmp(horizontalAlignment, "center") == 0 ? 1
                    : strcmp(horizontalAlignment, "trailing") == 0 ? 2 : 0;
                const char* verticalAlignment = textBoxJson["verticalAlignment"] | "top";
                control.textVerticalAlignment = strcmp(verticalAlignment, "center") == 0 ? 1
                    : strcmp(verticalAlignment, "bottom") == 0 ? 2 : 0;
                const char* tapBehavior = textBoxJson["tapBehavior"] | "displayOnly";
                control.tapBehavior = strcmp(tapBehavior, "refresh") == 0 ? 1
                    : strcmp(tapBehavior, "action") == 0 ? 2 : 0;
                const uint32_t refreshSeconds = textBoxJson["refreshIntervalSeconds"] | 0;
                control.refreshIntervalMs = refreshSeconds == 0
                    ? 0 : constrain(refreshSeconds, 5UL, 3600UL) * 1000UL;
            } else {
                control.gridWidth = 1;
                control.gridHeight = control.slider
                    ? 1 : constrain(controlJson["buttonHeight"] | 2, 1, 2);
            }
            JsonObject actionJson = controlJson["action"];
            strlcpy(control.action.type, actionJson["type"] | "", sizeof(control.action.type));
            strlcpy(control.action.host, actionJson["host"] | "", sizeof(control.action.host));
            strlcpy(control.action.text, actionJson["text"] | "", sizeof(control.action.text));
            control.action.value = actionJson["value"] | 0;
            strlcpy(
                control.action.computerId,
                actionJson["computerID"] | "",
                sizeof(control.action.computerId));
            for (const char* modifier : actionJson["modifiers"].as<JsonArray>()) {
                if (control.action.modifierCount >= 4) {
                    break;
                }
                strlcpy(
                    control.action.modifiers[control.action.modifierCount++],
                    modifier,
                    sizeof(control.action.modifiers[0]));
            }
            if (strcmp(control.action.type, "page") == 0) {
                control.toggle = false;
            }
            ++page.controlCount;
        }
        ++output.pageCount;
    }
    if (output.pageCount == 0) {
        return false;
    }
    restoreRemoteSliderPositions(output);
    restoreRemoteToggleStates(output);
    output.configured = true;
    return true;
}

bool loadRemoteProfile() {
    if (remoteProfile == nullptr || pendingRemoteProfile == nullptr ||
        !parseRemoteProfile(kRemoteProfilePath, *pendingRemoteProfile)) {
        return false;
    }
    *remoteProfile = *pendingRemoteProfile;
    remotePageIndex = min(remotePageIndex, static_cast<uint8_t>(remoteProfile->pageCount - 1));
    return true;
}

void preserveRemoteTextBoxValues(const RemoteProfile& previous, RemoteProfile& current) {
    for (uint8_t pageIndex = 0; pageIndex < current.pageCount; ++pageIndex) {
        RemotePage& page = current.pages[pageIndex];
        for (uint8_t controlIndex = 0; controlIndex < page.controlCount; ++controlIndex) {
            RemoteControl& control = page.controls[controlIndex];
            if (control.kind != 2 || !isMacTextSource(control)) {
                continue;
            }
            for (uint8_t previousPageIndex = 0; previousPageIndex < previous.pageCount; ++previousPageIndex) {
                const RemotePage& previousPage = previous.pages[previousPageIndex];
                for (uint8_t previousControlIndex = 0;
                     previousControlIndex < previousPage.controlCount;
                     ++previousControlIndex) {
                    const RemoteControl& previousControl = previousPage.controls[previousControlIndex];
                    const bool sameSource = previousControl.kind == 2 &&
                        strcmp(previousControl.id, control.id) == 0 &&
                        strcmp(previousControl.textSource, control.textSource) == 0 &&
                        strcmp(previousControl.sourceText, control.sourceText) == 0 &&
                        strcmp(previousControl.textComputerId, control.textComputerId) == 0;
                    if (!sameSource) {
                        continue;
                    }
                    if (previousControl.hasResolvedValue) {
                        strlcpy(
                            control.resolvedText,
                            previousControl.resolvedText,
                            sizeof(control.resolvedText));
                        control.hasResolvedValue = true;
                    }
                    previousPageIndex = previous.pageCount;
                    break;
                }
            }
        }
    }
}

bool installTemporaryRemoteProfile() {
    if (remoteProfile == nullptr || pendingRemoteProfile == nullptr ||
        !parseRemoteProfile(kRemoteProfileTemporaryPath, *pendingRemoteProfile)) {
        SD.remove(kRemoteProfileTemporaryPath);
        return false;
    }
    SD.remove(kRemoteProfilePath);
    if (!SD.rename(kRemoteProfileTemporaryPath, kRemoteProfilePath)) {
        SD.remove(kRemoteProfileTemporaryPath);
        return false;
    }

    char visiblePageId[sizeof(RemotePage::id)] = {};
    const uint8_t previousPageIndex = remotePageIndex;
    const bool canPartiallyRefresh = remoteVisible && !screensaverActive;
    if (remotePageIndex < remoteProfile->pageCount) {
        strlcpy(visiblePageId, remoteProfile->pages[remotePageIndex].id, sizeof(visiblePageId));
    }
    RemoteProfile* previousProfile = remoteProfile;
    remoteProfile = pendingRemoteProfile;
    pendingRemoteProfile = previousProfile;
    preserveRemoteTextBoxValues(*pendingRemoteProfile, *remoteProfile);
    if (remoteProfile->hasDeviceClock) {
        M5.Rtc.setDateTime(remoteProfile->deviceClock);
    }
    remotePageIndex = min(previousPageIndex, static_cast<uint8_t>(remoteProfile->pageCount - 1));
    bool preservedVisiblePage = false;
    for (uint8_t index = 0; index < remoteProfile->pageCount; ++index) {
        if (visiblePageId[0] != '\0' && strcmp(remoteProfile->pages[index].id, visiblePageId) == 0) {
            remotePageIndex = index;
            preservedVisiblePage = true;
            break;
        }
    }
    const bool wifiChanged = strcmp(pendingRemoteProfile->wifiSsid, remoteProfile->wifiSsid) != 0 ||
        strcmp(pendingRemoteProfile->wifiPassword, remoteProfile->wifiPassword) != 0;
    remoteVisible = true;
    screensaverActive = false;
    lastRemoteActivityAt = millis();
    if (wifiChanged) {
        homeWifiAuthenticationFailures = 0;
        homeWifiAuthenticationRetryPending = false;
        connectHomeWifi();
    }
    if (canPartiallyRefresh && preservedVisiblePage && !wifiChanged) {
        prepareRemoteTextBoxes();
        displayRemoteProfileChanges(*pendingRemoteProfile, previousPageIndex);
    } else {
        displayRemote();
    }
    return true;
}

void initializeDefaultRemoteProfile() {
    if (remoteProfile == nullptr) {
        return;
    }
    memset(remoteProfile, 0, sizeof(*remoteProfile));
    remoteProfile->macPort = 43821;
    remoteProfile->screensaverDelayMs = 30000;
    remoteProfile->pageCount = 1;
    remoteProfile->configured = true;

    RemotePage& page = remoteProfile->pages[0];
    strlcpy(page.id, "main", sizeof(page.id));
    strlcpy(page.name, "REMOTE", sizeof(page.name));
    page.controlCount = 3;

    strlcpy(page.controls[0].title, "Previous", sizeof(page.controls[0].title));
    strlcpy(page.controls[0].symbol, "backward.fill", sizeof(page.controls[0].symbol));
    strlcpy(page.controls[0].action.type, "macMedia", sizeof(page.controls[0].action.type));
    strlcpy(page.controls[0].action.text, "previous", sizeof(page.controls[0].action.text));

    strlcpy(page.controls[1].title, "Play / Pause", sizeof(page.controls[1].title));
    strlcpy(page.controls[1].symbol, "playpause.fill", sizeof(page.controls[1].symbol));
    strlcpy(page.controls[1].action.type, "macMedia", sizeof(page.controls[1].action.type));
    strlcpy(page.controls[1].action.text, "playPause", sizeof(page.controls[1].action.text));

    strlcpy(page.controls[2].title, "Next", sizeof(page.controls[2].title));
    strlcpy(page.controls[2].symbol, "forward.fill", sizeof(page.controls[2].symbol));
    strlcpy(page.controls[2].action.type, "macMedia", sizeof(page.controls[2].action.type));
    strlcpy(page.controls[2].action.text, "next", sizeof(page.controls[2].action.text));
}

struct SideButton {
    int pin;
    bool rawPressed = false;
    bool pressed = false;
    uint32_t changedAt = 0;

    explicit SideButton(int buttonPin) : pin(buttonPin) {}

    bool update(uint32_t now) {
        const bool currentRawPressed = digitalRead(pin) == LOW;
        if (currentRawPressed != rawPressed) {
            rawPressed = currentRawPressed;
            changedAt = now;
        }
        if (pressed != rawPressed && now - changedAt >= 25) {
            pressed = rawPressed;
            return pressed;
        }
        return false;
    }
};

SideButton previousButton{kPreviousButtonPin};
SideButton menuButton{kMenuButtonPin};
SideButton nextButton{kNextButtonPin};

void drawLibraryRow(size_t itemIndex, bool clearRow) {
    if (itemIndex >= libraryItemCount) {
        return;
    }
    const size_t row = itemIndex % kLibraryRowsPerPage;
    const int32_t y = kLibraryRowTop + static_cast<int32_t>(row) * kLibraryRowHeight;
    const LibraryItem& item = libraryItems[itemIndex];
    const bool active = strcmp(item.path, activeAnimationPath) == 0;
    const bool selected = itemIndex == librarySelection;

    if (clearRow) {
        M5.Display.fillRect(28, y + 2, 484, kLibraryRowHeight - 3, TFT_WHITE);
    }
    if (selected) {
        M5.Display.drawRect(28, y + 4, 484, kLibraryRowHeight - 8, TFT_BLACK);
        M5.Display.drawRect(29, y + 5, 482, kLibraryRowHeight - 10, TFT_BLACK);
    }
    if (active) {
        M5.Display.fillRect(34, y + 30, 18, 18, TFT_BLACK);
    } else {
        M5.Display.drawRect(34, y + 30, 18, 18, TFT_BLACK);
    }

    char displayTitle[27];
    strlcpy(displayTitle, item.title, sizeof(displayTitle));
    M5.Display.setFont(&fonts::FreeSansBold12pt7b);
    size_t titleLength = strlen(displayTitle);
    while (titleLength > 3 && M5.Display.textWidth(displayTitle) > 420) {
        displayTitle[--titleLength] = '\0';
    }
    if (titleLength < strlen(item.title) && titleLength >= 3) {
        memcpy(displayTitle + titleLength - 3, "...", 3);
    }
    M5.Display.drawString(displayTitle, 72, y + 12);

    char detail[24];
    snprintf(detail, sizeof(detail), "%s  %u frame%s",
        item.frameCount == 1 ? "IMAGE" : "GIF",
        item.frameCount,
        item.frameCount == 1 ? "" : "s");
    M5.Display.setFont(&fonts::FreeMono9pt7b);
    M5.Display.drawString(detail, 73, y + 52);
    M5.Display.drawFastHLine(32, y + kLibraryRowHeight - 1, 476, TFT_BLACK);
}

uint16_t readLittleEndian16(const uint8_t* bytes) {
    return static_cast<uint16_t>(bytes[0]) |
           (static_cast<uint16_t>(bytes[1]) << 8);
}

uint32_t readLittleEndian32(const uint8_t* bytes) {
    return static_cast<uint32_t>(bytes[0]) |
           (static_cast<uint32_t>(bytes[1]) << 8) |
           (static_cast<uint32_t>(bytes[2]) << 16) |
           (static_cast<uint32_t>(bytes[3]) << 24);
}

uint32_t updateCrc32(uint32_t crc, const uint8_t* bytes, size_t length) {
    for (size_t index = 0; index < length; ++index) {
        crc ^= bytes[index];
        for (uint8_t bit = 0; bit < 8; ++bit) {
            crc = (crc >> 1) ^ ((crc & 1U) ? 0xEDB88320U : 0U);
        }
    }
    return crc;
}

bool initializeSdCard() {
    constexpr uint32_t frequencies[] = {25000000, 10000000};
    for (const uint32_t frequency : frequencies) {
        SPI.end();
        delay(250);
        SPI.begin(kSdSclk, kSdMiso, kSdMosi, kSdCs);
        if (SD.begin(kSdCs, SPI, frequency)) {
            Serial.printf("SD mounted at %lu Hz\n", static_cast<unsigned long>(frequency));
            return true;
        }
        SD.end();
        Serial.printf("SD mount failed at %lu Hz\n", static_cast<unsigned long>(frequency));
    }
    return false;
}

void notifyControl(uint8_t status) {
    if (controlCharacteristic != nullptr) {
        controlCharacteristic->setValue(&status, 1);
        controlCharacteristic->notify();
    }
}

void notifyUploadProgress() {
    if (controlCharacteristic == nullptr) {
        return;
    }
    const uint8_t response[] = {
        kUploadProgress,
        static_cast<uint8_t>(upload.receivedBytes),
        static_cast<uint8_t>(upload.receivedBytes >> 8),
        static_cast<uint8_t>(upload.receivedBytes >> 16),
        static_cast<uint8_t>(upload.receivedBytes >> 24),
    };
    controlCharacteristic->setValue(response, sizeof(response));
    controlCharacteristic->notify();
}

void notifyRemoteProfileProgress() {
    if (controlCharacteristic == nullptr) {
        return;
    }
    const uint8_t response[] = {
        kRemoteProfileProgress,
        static_cast<uint8_t>(remoteProfileUpload.receivedBytes),
        static_cast<uint8_t>(remoteProfileUpload.receivedBytes >> 8),
        static_cast<uint8_t>(remoteProfileUpload.receivedBytes >> 16),
        static_cast<uint8_t>(remoteProfileUpload.receivedBytes >> 24),
    };
    controlCharacteristic->setValue(response, sizeof(response));
    controlCharacteristic->notify();
}

void notifyWifiInfo() {
    if (controlCharacteristic == nullptr) {
        return;
    }
    uint8_t response[1 + sizeof(wifiSsid)] = {kWifiInfo};
    const size_t ssidLength = strlen(wifiSsid);
    memcpy(response + 1, wifiSsid, ssidLength);
    controlCharacteristic->setValue(response, 1 + ssidLength);
    controlCharacteristic->notify();
}

void scanWifiNetworks() {
    wifiScanRequested = false;
    WiFi.scanDelete();
    if (WiFi.getMode() == WIFI_OFF) {
        WiFi.mode(WIFI_STA);
    }
    const int resultCount = WiFi.scanNetworks(false, true);
    wifiScanResultCount = max(0, resultCount);
    const uint8_t visibleCount = static_cast<uint8_t>(min<int16_t>(wifiScanResultCount, 255));
    const uint8_t response[] = {kWifiNetworkCount, visibleCount};
    controlCharacteristic->setValue(response, sizeof(response));
    controlCharacteristic->notify();
    Serial.printf("Wi-Fi scan found %d networks\n", wifiScanResultCount);
}

void notifyWifiNetwork(uint8_t index) {
    if (index >= wifiScanResultCount) {
        notifyControl(kUploadFailed);
        return;
    }
    const String ssid = WiFi.SSID(index);
    const size_t ssidLength = min(static_cast<size_t>(ssid.length()), static_cast<size_t>(32));
    uint8_t response[4 + 32] = {
        kReadWifiNetwork,
        index,
        static_cast<uint8_t>(constrain(WiFi.RSSI(index), -127, 0)),
        WiFi.encryptionType(index) == WIFI_AUTH_OPEN ? static_cast<uint8_t>(0) : static_cast<uint8_t>(1),
    };
    memcpy(response + 4, ssid.c_str(), ssidLength);
    controlCharacteristic->setValue(response, 4 + ssidLength);
    controlCharacteristic->notify();
}

void notifyHomeWifiStatus() {
    if (controlCharacteristic == nullptr) {
        return;
    }
    uint8_t response[16] = {
        kHomeWifiStatus,
        homeWifiState,
        static_cast<uint8_t>(homeWifiFailureReason),
        static_cast<uint8_t>(homeWifiFailureReason >> 8),
    };
    const IPAddress address = homeWifiState == 2 ? WiFi.localIP() : IPAddress(0, 0, 0, 0);
    for (uint8_t index = 0; index < 4; ++index) {
        response[4 + index] = address[index];
    }
    for (uint8_t index = 0; index < 8; ++index) {
        response[8 + index] = static_cast<uint8_t>(homeWifiSessionToken >> ((7 - index) * 8));
    }
    controlCharacteristic->setValue(response, sizeof(response));
    controlCharacteristic->notify();
}

void notifyLibraryCount() {
    refreshLibrary();
    const uint8_t response[] = {kLibraryCount, static_cast<uint8_t>(libraryItemCount)};
    controlCharacteristic->setValue(response, sizeof(response));
    controlCharacteristic->notify();
}

void notifyLibraryItem(uint8_t index) {
    if (index >= libraryItemCount) {
        notifyControl(kUploadFailed);
        return;
    }
    const LibraryItem& item = libraryItems[index];
    const size_t titleLength = min(strlen(item.title), kMaximumTitleBytes);
    uint8_t response[5 + kMaximumTitleBytes];
    response[0] = kReadLibraryItem;
    response[1] = index;
    response[2] = strcmp(item.path, activeAnimationPath) == 0 ? 1 : 0;
    response[3] = static_cast<uint8_t>(item.frameCount);
    response[4] = static_cast<uint8_t>(item.frameCount >> 8);
    memcpy(response + 5, item.title, titleLength);
    controlCharacteristic->setValue(response, 5 + titleLength);
    controlCharacteristic->notify();
}

void closeAnimation() {
    animationReady = false;
    animationFile.close();
    free(frameDurations);
    frameDurations = nullptr;
}

void resetWifiUploadState() {
    wifiUploadSucceeded = false;
    wifiUploadFailed = false;
    wifiUploadRequestAccepted = false;
    wifiUploadRequestFinal = false;
    wifiUploadRequestOffset = 0;
    wifiUploadExpectedChunkBytes = 0;
    wifiWriteBufferLength = 0;
}

void cancelUpload(bool notifyFailure) {
    upload.file.close();
    resetWifiUploadState();
    wifiUploadStartedAt = 0;
    if (bluetoothSuspendedForWifiUpload) {
        bluetoothResumeRequested = true;
    }
    upload = UploadState{};
    finishRequested = false;
    if (SD.exists(kTemporaryPath)) {
        SD.remove(kTemporaryPath);
    }
    if (notifyFailure) {
        notifyControl(kUploadFailed);
    }
}

void cancelRemoteProfileUpload(bool notifyFailure) {
    remoteProfileUpload.file.close();
    remoteProfileUpload = RemoteProfileUploadState{};
    if (SD.exists(kRemoteProfileTemporaryPath)) {
        SD.remove(kRemoteProfileTemporaryPath);
    }
    if (notifyFailure) {
        notifyControl(kUploadFailed);
    }
}

bool readExact(File& file, uint8_t* destination, size_t length) {
    return file.read(destination, length) == length;
}

bool sdHasSpaceFor(uint32_t bytes) {
    if (!sdReady) {
        return false;
    }
    const uint64_t totalBytes = SD.totalBytes();
    const uint64_t usedBytes = SD.usedBytes();
    return totalBytes >= usedBytes && static_cast<uint64_t>(bytes) <= totalBytes - usedBytes;
}

bool parseAnimation(File& file, AnimationHeader& header, uint16_t*& durations) {
    if (file.size() < kHeaderBytes || !file.seek(0)) {
        return false;
    }

    uint8_t bytes[kHeaderBytes];
    if (!readExact(file, bytes, sizeof(bytes)) || memcmp(bytes, "PGIF", 4) != 0) {
        return false;
    }

    const uint16_t version = readLittleEndian16(bytes + 4);
    const uint16_t width = readLittleEndian16(bytes + 6);
    const uint16_t height = readLittleEndian16(bytes + 8);
    const uint16_t frameCount = readLittleEndian16(bytes + 10);
    const uint32_t frameBytes = readLittleEndian32(bytes + 12);
    const uint16_t scanRateHz = readLittleEndian16(bytes + 16);
    const uint8_t transitionScans = bytes[18];
    const uint8_t adaptiveCleaning = bytes[19];
    const uint16_t cleanRefreshInterval = readLittleEndian16(bytes + 20);

    const bool supportedLayout =
        (version == 4 && frameBytes == kGrayscaleFrameBytes) ||
        (version == 3 && frameBytes == kFrameBytes) ||
        (version == 2 && frameBytes == kLegacyFrameBytes);
    const uint64_t expectedSize = kHeaderBytes +
        static_cast<uint64_t>(frameCount) * sizeof(uint16_t) +
        static_cast<uint64_t>(frameCount) * frameBytes;
    if (!supportedLayout || width != kDisplayWidth || height != kDisplayHeight ||
        frameCount == 0 || expectedSize != file.size() ||
        scanRateHz == 0 || scanRateHz > 60 || transitionScans == 0 ||
        transitionScans > 9 || adaptiveCleaning > 1 || cleanRefreshInterval == 0) {
        return false;
    }

    durations = static_cast<uint16_t*>(heap_caps_malloc(
        static_cast<size_t>(frameCount) * sizeof(uint16_t), MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
    if (durations == nullptr) {
        durations = static_cast<uint16_t*>(malloc(static_cast<size_t>(frameCount) * sizeof(uint16_t)));
    }
    if (durations == nullptr) {
        return false;
    }

    for (uint16_t index = 0; index < frameCount; ++index) {
        uint8_t durationBytes[2];
        if (!readExact(file, durationBytes, sizeof(durationBytes))) {
            free(durations);
            durations = nullptr;
            return false;
        }
        durations[index] = readLittleEndian16(durationBytes);
        if (durations[index] == 0) {
            free(durations);
            durations = nullptr;
            return false;
        }
    }

    header.frameCount = frameCount;
    header.scanRateHz = scanRateHz;
    header.transitionScans = transitionScans;
    header.adaptiveCleaning = adaptiveCleaning == 1;
    header.cleanRefreshInterval = cleanRefreshInterval;
    header.frameBytes = frameBytes;
    header.framesOffset = kHeaderBytes + static_cast<uint32_t>(frameCount) * sizeof(uint16_t);
    header.grayscale = version == 4;
    return true;
}

bool loadAnimation(const char* path) {
    closeAnimation();
    animationFile = SD.open(path, FILE_READ);
    if (!animationFile) {
        return false;
    }

    uint16_t* durations = nullptr;
    AnimationHeader header;
    if (!parseAnimation(animationFile, header, durations)) {
        animationFile.close();
        return false;
    }

    animationHeader = header;
    frameDurations = durations;
    currentFrame = 0;
    displayedFrames = 0;
    stillFrameDisplayed = false;
    previousFrameValid = false;
    nextFrameAt = millis();
    nextSlideshowAt = millis() + slideshowIntervalMs();
    animationReady = true;
    strlcpy(activeAnimationPath, path, sizeof(activeAnimationPath));
    return true;
}

bool loadAnimation() {
    return loadAnimation(activeAnimationPath);
}

void sidecarPathFor(const char* packagePath, char* sidecarPath, size_t capacity) {
    strlcpy(sidecarPath, packagePath, capacity);
    char* extension = strrchr(sidecarPath, '.');
    if (extension != nullptr) {
        strlcpy(extension, ".txt", capacity - static_cast<size_t>(extension - sidecarPath));
    }
}

void readLibraryTitle(const char* packagePath, char* title, size_t capacity) {
    char sidecarPath[kMaximumPathBytes];
    sidecarPathFor(packagePath, sidecarPath, sizeof(sidecarPath));
    File titleFile = SD.open(sidecarPath, FILE_READ);
    if (titleFile) {
        const size_t length = titleFile.readBytes(title, capacity - 1);
        title[length] = '\0';
        titleFile.close();
    }
    if (title[0] == '\0') {
        strlcpy(title, "Untitled", capacity);
    }
}

bool readLibraryItem(const char* path, LibraryItem& item) {
    File file = SD.open(path, FILE_READ);
    if (!file) {
        return false;
    }

    AnimationHeader header;
    uint16_t* durations = nullptr;
    const bool valid = parseAnimation(file, header, durations);
    file.close();
    free(durations);
    if (!valid) {
        return false;
    }

    strlcpy(item.path, path, sizeof(item.path));
    item.frameCount = header.frameCount;
    if (strcmp(path, kAnimationPath) == 0) {
        strlcpy(item.title, "Current Media", sizeof(item.title));
    } else {
        readLibraryTitle(path, item.title, sizeof(item.title));
    }
    return true;
}

void libraryItemId(const LibraryItem& item, char* identifier, size_t capacity) {
    const char* filename = strrchr(item.path, '/');
    filename = filename == nullptr ? item.path : filename + 1;
    strlcpy(identifier, filename, capacity);
    char* extension = strrchr(identifier, '.');
    if (extension != nullptr) {
        *extension = '\0';
    }
}

void refreshLibrary() {
    libraryItemCount = 0;
    if (SD.exists(kAnimationPath)) {
        LibraryItem item;
        if (readLibraryItem(kAnimationPath, item)) {
            libraryItems[libraryItemCount++] = item;
        }
    }

    File directory = SD.open(kLibraryDirectory);
    if (!directory || !directory.isDirectory()) {
        return;
    }
    File entry = directory.openNextFile();
    while (entry && libraryItemCount < kMaximumLibraryItems) {
        if (!entry.isDirectory()) {
            const char* name = entry.name();
            const char* extension = strrchr(name, '.');
            if (extension != nullptr && strcasecmp(extension, ".pgif") == 0) {
                char path[kMaximumPathBytes];
                if (name[0] == '/') {
                    strlcpy(path, name, sizeof(path));
                } else {
                    snprintf(path, sizeof(path), "%s/%s", kLibraryDirectory, name);
                }
                LibraryItem item;
                if (readLibraryItem(path, item)) {
                    libraryItems[libraryItemCount++] = item;
                }
            }
        }
        entry.close();
        entry = directory.openNextFile();
    }
    directory.close();

    const size_t pageCount = max(static_cast<size_t>(1),
        (libraryItemCount + kLibraryRowsPerPage - 1) / kLibraryRowsPerPage);
    if (libraryPage >= pageCount) {
        libraryPage = pageCount - 1;
    }
}

bool deleteLibraryItem(uint8_t index) {
    refreshLibrary();
    if (index >= libraryItemCount) {
        return false;
    }

    char path[kMaximumPathBytes];
    strlcpy(path, libraryItems[index].path, sizeof(path));
    const bool deletingActiveItem = strcmp(path, activeAnimationPath) == 0;
    if (deletingActiveItem) {
        closeAnimation();
    }

    char sidecarPath[kMaximumPathBytes];
    sidecarPathFor(path, sidecarPath, sizeof(sidecarPath));
    const bool removed = SD.remove(path);
    if (!removed) {
        if (deletingActiveItem) {
            loadAnimation(path);
        }
        return false;
    }
    SD.remove(sidecarPath);
    refreshLibrary();

    if (deletingActiveItem) {
        SD.remove(kActivePath);
        if (libraryItemCount > 0) {
            const size_t replacementIndex = min(static_cast<size_t>(index), libraryItemCount - 1);
            if (loadAnimation(libraryItems[replacementIndex].path)) {
                persistActiveSelection();
                displayCurrentFrame();
            }
        } else {
            animationReady = false;
            splashPending = true;
        }
    }
    if (libraryVisible) {
        librarySelection = min(static_cast<size_t>(index),
            libraryItemCount == 0 ? static_cast<size_t>(0) : libraryItemCount - 1);
        libraryPage = librarySelection / kLibraryRowsPerPage;
        displayLibrary();
    }
    return true;
}

void persistActiveSelection() {
    SD.remove(kActivePath);
    File file = SD.open(kActivePath, FILE_WRITE);
    if (file) {
        file.print(activeAnimationPath);
        file.close();
    }
}

void restoreActiveSelection() {
    if (!SD.exists(kActivePath)) {
        return;
    }
    File file = SD.open(kActivePath, FILE_READ);
    if (!file) {
        return;
    }
    char path[kMaximumPathBytes] = {};
    const size_t length = file.readBytes(path, sizeof(path) - 1);
    path[length] = '\0';
    file.close();
    if (path[0] != '\0' && SD.exists(path)) {
        strlcpy(activeAnimationPath, path, sizeof(activeAnimationPath));
    }
}

bool installTemporaryAnimation() {
    File candidate = SD.open(kTemporaryPath, FILE_READ);
    if (!candidate) {
        return false;
    }

    AnimationHeader candidateHeader;
    uint16_t* candidateDurations = nullptr;
    const bool valid = parseAnimation(candidate, candidateHeader, candidateDurations);
    candidate.close();
    free(candidateDurations);
    if (!valid) {
        return false;
    }

    const char* destinationPath = upload.destinationPath;
    closeAnimation();
    SD.remove(kBackupPath);
    const bool hadAnimation = SD.exists(destinationPath);
    if (hadAnimation && !SD.rename(destinationPath, kBackupPath)) {
        return false;
    }
    if (!SD.rename(kTemporaryPath, destinationPath)) {
        if (hadAnimation) {
            SD.rename(kBackupPath, destinationPath);
        }
        return false;
    }

    char sidecarPath[kMaximumPathBytes];
    sidecarPathFor(destinationPath, sidecarPath, sizeof(sidecarPath));
    SD.remove(sidecarPath);
    File titleFile = SD.open(sidecarPath, FILE_WRITE);
    if (titleFile) {
        titleFile.print(upload.title);
        titleFile.close();
    }

    if (loadAnimation(destinationPath)) {
        persistActiveSelection();
        SD.remove(kBackupPath);
        refreshLibrary();
        for (size_t index = 0; index < libraryItemCount; ++index) {
            if (strcmp(libraryItems[index].path, destinationPath) == 0) {
                return true;
            }
        }
    }

    SD.remove(destinationPath);
    if (hadAnimation) {
        SD.rename(kBackupPath, destinationPath);
        loadAnimation();
    }
    return false;
}

bool writeWifiUploadBuffer(const uint8_t* bytes, size_t length) {
    size_t totalWritten = 0;
    for (uint8_t attempt = 0; attempt < 3 && totalWritten < length; ++attempt) {
        errno = 0;
        const size_t written = upload.file.write(bytes + totalWritten, length - totalWritten);
        const int writeError = errno;
        totalWritten += written;
        if (totalWritten == length) {
            return true;
        }

        const size_t resumeOffset = upload.file.position();
        Serial.printf(
            "Wi-Fi SD short write: wrote=%u/%u position=%u attempt=%u errno=%d\n",
            static_cast<unsigned>(totalWritten), static_cast<unsigned>(length),
            static_cast<unsigned>(resumeOffset), static_cast<unsigned>(attempt + 1), writeError);
        upload.file.flush();
        upload.file.close();
        delay(20);
        upload.file = SD.open(kTemporaryPath, "r+");
        if (!upload.file || !upload.file.seek(resumeOffset)) {
            return false;
        }
    }
    return totalWritten == length;
}

bool appendWifiUpload(const uint8_t* bytes, size_t length) {
    while (length > 0) {
        const size_t available = kWifiWriteBufferBytes - wifiWriteBufferLength;
        const size_t copied = min(length, available);
        memcpy(wifiWriteBuffer + wifiWriteBufferLength, bytes, copied);
        wifiWriteBufferLength += copied;
        bytes += copied;
        length -= copied;

        if (wifiWriteBufferLength == kWifiWriteBufferBytes) {
            if (!writeWifiUploadBuffer(wifiWriteBuffer, wifiWriteBufferLength)) {
                return false;
            }
            wifiWriteBufferLength = 0;
        }
    }
    return true;
}

bool flushWifiUpload() {
    if (wifiWriteBufferLength == 0) {
        return true;
    }
    const size_t length = wifiWriteBufferLength;
    wifiWriteBufferLength = 0;
    return writeWifiUploadBuffer(wifiWriteBuffer, length);
}

void configureWifiServer() {
    if (wifiServerConfigured) {
        return;
    }
    const char* headerKeys[] = {
        "X-PGIF-Size",
        "X-PGIF-Offset",
        "X-PGIF-Chunk-Size",
        "X-PGIF-Final",
        "Authorization",
    };
    wifiServer.collectHeaders(headerKeys, 5);
    wifiServer.on("/status", HTTP_GET, []() {
        char response[128];
        snprintf(response, sizeof(response),
            "{\"device\":\"paperGIF\",\"ready\":%s,\"uploading\":%s,\"ssid\":\"%s\"}",
            sdReady && !upload.active ? "true" : "false",
            upload.active ? "true" : "false",
            wifiSsid);
        wifiServer.send(200, "application/json", response);
    });
    wifiServer.on("/wifi/networks", HTTP_GET, []() {
        if (!wifiRequestAuthorized()) {
            wifiServer.send(401, "application/json", "{\"ok\":false,\"error\":\"unauthorized\"}");
            return;
        }
        WiFi.scanDelete();
        const int resultCount = WiFi.scanNetworks(false, true);
        String response;
        response.reserve(64 + max(0, resultCount) * 80);
        response = "{\"networks\":[";
        for (int index = 0; index < resultCount; ++index) {
            if (index > 0) {
                response += ',';
            }
            response += "{\"ssid\":";
            appendJsonString(response, WiFi.SSID(index).c_str());
            response += ",\"rssi\":";
            response += WiFi.RSSI(index);
            response += ",\"secure\":";
            response += WiFi.encryptionType(index) == WIFI_AUTH_OPEN ? "false" : "true";
            response += '}';
        }
        response += "]}";
        wifiServer.send(200, "application/json", response);
    });
    wifiServer.on("/library", HTTP_GET, []() {
        if (!wifiRequestFromAccessPoint()) {
            wifiServer.send(403, "application/json", "{\"ok\":false,\"error\":\"ap_only\"}");
            return;
        }
        String response;
        response.reserve(128 + libraryItemCount * 96);
        response = "{\"items\":[";
        for (size_t index = 0; index < libraryItemCount; ++index) {
            if (index > 0) {
                response += ',';
            }
            response += "{\"index\":";
            response += static_cast<unsigned>(index);
            response += ",\"id\":";
            char identifier[16];
            libraryItemId(libraryItems[index], identifier, sizeof(identifier));
            appendJsonString(response, identifier);
            response += ",\"name\":";
            appendJsonString(response, libraryItems[index].title);
            response += ",\"frameCount\":";
            response += libraryItems[index].frameCount;
            response += ",\"active\":";
            response += strcmp(libraryItems[index].path, activeAnimationPath) == 0 ? "true" : "false";
            response += '}';
        }
        response += "]}";
        wifiServer.send(200, "application/json", response);
    });
    wifiServer.on("/library/active", HTTP_POST, []() {
        if (!wifiRequestFromAccessPoint()) {
            wifiServer.send(403, "application/json", "{\"ok\":false,\"error\":\"ap_only\"}");
            return;
        }
        const int index = wifiServer.arg("index").toInt();
        if (index < 0 || index >= static_cast<int>(libraryItemCount)) {
            wifiServer.send(400, "application/json", "{\"ok\":false,\"error\":\"invalid_index\"}");
            return;
        }

        selectLibraryItem(static_cast<size_t>(index));
        wifiServer.send(200, "application/json", "{\"ok\":true}");
    });
    wifiServer.on("/wifi/off", HTTP_POST, []() {
        if (!wifiRequestFromAccessPoint()) {
            wifiServer.send(403, "application/json", "{\"ok\":false,\"error\":\"ap_only\"}");
            return;
        }
        wifiServer.send(200, "application/json", "{\"ok\":true}");
        wifiStopRequested = true;
        wifiStopRequestedAt = millis();
    });
    wifiServer.on("/remote", HTTP_GET, []() {
        if (!wifiRequestAuthorized()) {
            wifiServer.send(401, "application/json", "{\"ok\":false,\"error\":\"unauthorized\"}");
            return;
        }
        File file = SD.open(kRemoteProfilePath, FILE_READ);
        if (!file) {
            wifiServer.send(404, "application/json", "{\"ok\":false,\"error\":\"profile_not_found\"}");
            return;
        }
        JsonDocument document;
        const DeserializationError error = deserializeJson(document, file);
        file.close();
        if (error) {
            wifiServer.send(500, "application/json", "{\"ok\":false,\"error\":\"profile_invalid\"}");
            return;
        }
        if (remoteProfile != nullptr) {
            for (JsonObject pageJson : document["pages"].as<JsonArray>()) {
                for (JsonObject controlJson : pageJson["controls"].as<JsonArray>()) {
                    const char* controlId = controlJson["id"] | "";
                    for (uint8_t pageIndex = 0; pageIndex < remoteProfile->pageCount; ++pageIndex) {
                        const RemotePage& page = remoteProfile->pages[pageIndex];
                        for (uint8_t controlIndex = 0; controlIndex < page.controlCount; ++controlIndex) {
                            const RemoteControl& control = page.controls[controlIndex];
                            if (control.slider && strcmp(control.id, controlId) == 0) {
                                controlJson["action"]["value"] = control.action.value;
                            }
                        }
                    }
                }
            }
        }
        String response;
        serializeJson(document, response);
        wifiServer.send(200, "application/json", response);
    });
    wifiServer.on("/remote", HTTP_POST, []() {
        if (!wifiRequestAuthorized()) {
            wifiServer.send(401, "application/json", "{\"ok\":false,\"error\":\"unauthorized\"}");
            return;
        }
        const String payload = wifiServer.arg("plain");
        if (!sdReady || upload.active || remoteProfileUpload.active ||
            payload.length() == 0 || payload.length() > kMaximumRemoteProfileBytes) {
            wifiServer.send(400, "application/json", "{\"ok\":false,\"error\":\"invalid_profile\"}");
            return;
        }

        SD.remove(kRemoteProfileTemporaryPath);
        File file = SD.open(kRemoteProfileTemporaryPath, FILE_WRITE);
        const bool written = file &&
            file.write(reinterpret_cast<const uint8_t*>(payload.c_str()), payload.length()) == payload.length();
        if (file) {
            file.flush();
            file.close();
        }
        if (!written || !installTemporaryRemoteProfile()) {
            SD.remove(kRemoteProfileTemporaryPath);
            wifiServer.send(400, "application/json", "{\"ok\":false,\"error\":\"invalid_profile\"}");
            return;
        }
        wifiServer.send(201, "application/json", "{\"ok\":true}");
    });
    wifiServer.on("/text-source/update", HTTP_POST, []() {
        if (!wifiRequestAuthorized()) {
            wifiServer.send(401, "application/json", "{\"ok\":false,\"error\":\"unauthorized\"}");
            return;
        }
        JsonDocument document;
        if (deserializeJson(document, wifiServer.arg("plain")) ||
            !document["items"].is<JsonArray>() || document["items"].size() > 16) {
            wifiServer.send(400, "application/json", "{\"ok\":false,\"error\":\"invalid_update\"}");
            return;
        }
        const uint32_t now = millis();
        for (JsonObject item : document["items"].as<JsonArray>()) {
            const char* identifier = item["id"] | "";
            const bool available = item["available"] | false;
            const char* text = item["text"] | "";
            for (uint8_t pageIndex = 0; remoteProfile != nullptr &&
                pageIndex < remoteProfile->pageCount; ++pageIndex) {
                RemotePage& page = remoteProfile->pages[pageIndex];
                for (uint8_t controlIndex = 0; controlIndex < page.controlCount; ++controlIndex) {
                    RemoteControl& control = page.controls[controlIndex];
                    if (control.kind != 2 || strcmp(control.textSource, "nowPlaying") != 0 ||
                        strcmp(control.id, identifier) != 0) {
                        continue;
                    }
                    control.nextRefreshAt = now + 60000;
                    if (!available && control.hasResolvedValue) {
                        continue;
                    }
                    const char* resolvedText = available ? text : control.placeholder;
                    const bool changed = strcmp(resolvedText, control.resolvedText) != 0;
                    strlcpy(control.resolvedText, resolvedText, sizeof(control.resolvedText));
                    control.hasResolvedValue = control.hasResolvedValue || available;
                    if (changed && remoteVisible && pageIndex == remotePageIndex) {
                        redrawRemoteTextBox(page, controlIndex);
                    }
                }
            }
        }
        wifiServer.send(200, "application/json", "{\"ok\":true}");
    });
    wifiServer.on("/upload", HTTP_POST, []() {
        if (!wifiRequestAuthorized()) {
            wifiServer.send(401, "application/json", "{\"ok\":false,\"error\":\"unauthorized\"}");
            return;
        }
        if (wifiUploadSucceeded) {
            char identifier[9];
            snprintf(identifier, sizeof(identifier), "%08lX", static_cast<unsigned long>(upload.expectedCrc));
            String response = "{\"ok\":true,\"id\":";
            appendJsonString(response, identifier);
            response += ",\"name\":";
            appendJsonString(response, upload.title);
            response += ",\"frameCount\":";
            response += animationHeader.frameCount;
            response += ",\"libraryCount\":";
            response += libraryItemCount;
            response += '}';
            wifiServer.send(201, "application/json", response);
        } else if (wifiUploadRequestAccepted && upload.active && !wifiUploadFailed) {
            char response[64];
            snprintf(response, sizeof(response),
                "{\"ok\":true,\"received\":%lu}",
                static_cast<unsigned long>(upload.receivedBytes));
            Serial.printf("Wi-Fi chunk acknowledged: received=%lu\n",
                static_cast<unsigned long>(upload.receivedBytes));
            wifiServer.send(200, "application/json", response);
        } else {
            Serial.printf("Wi-Fi request rejected: active=%d accepted=%d failed=%d received=%lu\n",
                upload.active, wifiUploadRequestAccepted, wifiUploadFailed,
                static_cast<unsigned long>(upload.receivedBytes));
            wifiServer.send(400, "application/json", "{\"ok\":false,\"error\":\"invalid_upload\"}");
        }
    }, []() {
        HTTPUpload& webUpload = wifiServer.upload();
        if (webUpload.status == UPLOAD_FILE_START) {
            resetWifiUploadState();
            if (!wifiRequestAuthorized()) {
                wifiUploadFailed = true;
                return;
            }
            const uint32_t requestOffset =
                static_cast<uint32_t>(wifiServer.header("X-PGIF-Offset").toInt());
            const uint32_t requestChunkBytes =
                static_cast<uint32_t>(wifiServer.header("X-PGIF-Chunk-Size").toInt());
            const bool requestFinal = wifiServer.header("X-PGIF-Final") == "1";
            const uint32_t expectedBytes =
                static_cast<uint32_t>(wifiServer.header("X-PGIF-Size").toInt());
            Serial.printf("Wi-Fi chunk start: offset=%lu chunk=%lu total=%lu final=%d\n",
                static_cast<unsigned long>(requestOffset),
                static_cast<unsigned long>(requestChunkBytes),
                static_cast<unsigned long>(expectedBytes), requestFinal);
            const bool requestInvalid =
                expectedBytes < kHeaderBytes + sizeof(uint16_t) + kLegacyFrameBytes ||
                requestOffset > expectedBytes || requestChunkBytes == 0 ||
                requestChunkBytes > expectedBytes - requestOffset ||
                requestFinal != (requestOffset + requestChunkBytes == expectedBytes);

            if (!requestInvalid && requestOffset == 0) {
                cancelUpload(false);
            }
            wifiUploadRequestOffset = requestOffset;
            wifiUploadExpectedChunkBytes = requestChunkBytes;
            wifiUploadRequestFinal = requestFinal;
            wifiUploadFailed = requestInvalid;

            if (!wifiUploadFailed && wifiUploadRequestOffset == 0) {
                closeAnimation();
                SD.remove(kTemporaryPath);
                const uint64_t totalBytes = SD.totalBytes();
                const uint64_t usedBytes = SD.usedBytes();
                Serial.printf("SD capacity: total=%llu used=%llu free=%llu requested=%lu\n",
                    totalBytes, usedBytes, totalBytes >= usedBytes ? totalBytes - usedBytes : 0,
                    static_cast<unsigned long>(expectedBytes));
                if (!sdHasSpaceFor(expectedBytes)) {
                    wifiUploadFailed = true;
                } else {
                    upload.file = SD.open(kTemporaryPath, FILE_WRITE);
                    upload.active = upload.file != false;
                    Serial.printf("Wi-Fi open temp: ok=%s\n",
                        upload.active ? "true" : "false");
                    if (upload.active) {
                        upload.file.seek(0);
                    }
                    upload.expectedBytes = expectedBytes;
                    upload.receivedBytes = 0;
                    upload.runningCrc = UINT32_MAX;
                    upload.lastActivityAt = millis();
                    wifiWriteBufferLength = 0;
                    wifiUploadStartedAt = millis();
                    String title = webUpload.filename;
                    const int extension = title.lastIndexOf('.');
                    if (extension > 0) {
                        title.remove(extension);
                    }
                    title.trim();
                    if (title.length() == 0) {
                        title = "Wi-Fi Upload";
                    }
                    strlcpy(upload.title, title.c_str(), sizeof(upload.title));
                    uploadScreenPending = false;
                }
            } else if (!wifiUploadFailed &&
                       (!upload.active || expectedBytes != upload.expectedBytes ||
                        wifiUploadRequestOffset != upload.receivedBytes)) {
                wifiUploadFailed = true;
            } else if (!wifiUploadFailed && wifiUploadRequestOffset > 0) {
                if (!upload.file || upload.file.position() != wifiUploadRequestOffset) {
                    upload.file.close();
                    upload.file = SD.open(kTemporaryPath, "r+");
                    if (!upload.file || !upload.file.seek(wifiUploadRequestOffset)) {
                        wifiUploadFailed = true;
                    }
                }
            }

            if (wifiUploadFailed || !upload.active) {
                Serial.printf("Wi-Fi chunk start failed: active=%d failed=%d received=%lu\n",
                    upload.active, wifiUploadFailed,
                    static_cast<unsigned long>(upload.receivedBytes));
                wifiUploadFailed = true;
                cancelUpload(false);
                loadAnimation();
                wifiScreenRefreshPending = true;
                wifiServer.client().stop();
                return;
            }
            wifiUploadRequestAccepted = true;
        } else if (webUpload.status == UPLOAD_FILE_WRITE &&
                   wifiUploadRequestAccepted && upload.active) {
            if (webUpload.currentSize > upload.expectedBytes - upload.receivedBytes) {
                Serial.printf("Wi-Fi chunk overflow: block=%u remaining=%lu\n",
                    static_cast<unsigned>(webUpload.currentSize),
                    static_cast<unsigned long>(upload.expectedBytes - upload.receivedBytes));
                wifiUploadFailed = true;
                wifiUploadRequestAccepted = false;
                cancelUpload(false);
                loadAnimation();
                wifiScreenRefreshPending = true;
                wifiServer.client().stop();
                return;
            }
            if (!appendWifiUpload(webUpload.buf, webUpload.currentSize)) {
                Serial.printf("Wi-Fi SD write failed at %lu bytes\n",
                    static_cast<unsigned long>(upload.receivedBytes));
                wifiUploadFailed = true;
                wifiUploadRequestAccepted = false;
                cancelUpload(false);
                loadAnimation();
                wifiScreenRefreshPending = true;
                wifiServer.client().stop();
                return;
            }
            upload.runningCrc = updateCrc32(upload.runningCrc, webUpload.buf, webUpload.currentSize);
            upload.receivedBytes += webUpload.currentSize;
            upload.lastActivityAt = millis();
        } else if (webUpload.status == UPLOAD_FILE_END &&
                   wifiUploadRequestAccepted && upload.active) {
            const size_t finalBytes = webUpload.currentSize;
            const uint32_t requestBytes = upload.receivedBytes - wifiUploadRequestOffset;
            if (requestBytes != wifiUploadExpectedChunkBytes || !flushWifiUpload()) {
                Serial.printf("Wi-Fi chunk end failed: request=%lu expected=%lu final=%zu\n",
                    static_cast<unsigned long>(requestBytes),
                    static_cast<unsigned long>(wifiUploadExpectedChunkBytes),
                    finalBytes);
                wifiUploadFailed = true;
                wifiUploadRequestAccepted = false;
                cancelUpload(false);
                loadAnimation();
                wifiScreenRefreshPending = true;
                wifiServer.client().stop();
                return;
            }
            Serial.printf("Wi-Fi chunk received: received=%lu\n",
                static_cast<unsigned long>(upload.receivedBytes));
            pendingUploadProgress = static_cast<uint8_t>(
                (static_cast<uint64_t>(upload.receivedBytes) * 100) / upload.expectedBytes);

            if (wifiUploadRequestFinal) {
                upload.file.flush();
                upload.file.close();
                upload.active = false;
                upload.expectedCrc = upload.runningCrc ^ UINT32_MAX;
                snprintf(upload.destinationPath, sizeof(upload.destinationPath),
                    "%s/%08lX.pgif", kLibraryDirectory,
                    static_cast<unsigned long>(upload.expectedCrc));
                const uint32_t uploadFinishedAt = millis();
                wifiUploadSucceeded = installTemporaryAnimation();
                const uint32_t installFinishedAt = millis();
                WiFi.setSleep(true);
                bluetoothResumeRequested = bluetoothSuspendedForWifiUpload;
                Serial.printf(
                    "Wi-Fi upload: %lu bytes in %lums, install=%lums, result=%s\n",
                    static_cast<unsigned long>(upload.receivedBytes),
                    static_cast<unsigned long>(uploadFinishedAt - wifiUploadStartedAt),
                    static_cast<unsigned long>(installFinishedAt - uploadFinishedAt),
                    wifiUploadSucceeded ? "ok" : "failed");
                wifiUploadFailed = !wifiUploadSucceeded;
                if (!wifiUploadSucceeded) {
                    SD.remove(kTemporaryPath);
                    loadAnimation();
                }
                wifiScreenRefreshPending = true;
            }
        } else if (webUpload.status == UPLOAD_FILE_ABORTED) {
            Serial.printf("Wi-Fi chunk aborted at %lu bytes\n",
                static_cast<unsigned long>(upload.receivedBytes));
            wifiUploadFailed = true;
            wifiUploadRequestAccepted = false;
            cancelUpload(false);
            loadAnimation();
            wifiScreenRefreshPending = true;
        }
    });
    wifiServer.onNotFound([]() {
        wifiServer.send(404, "application/json", "{\"ok\":false,\"error\":\"not_found\"}");
    });
    wifiServerConfigured = true;
}

void advertiseDeviceService() {
    if (mdnsRunning) {
        MDNS.end();
        mdnsRunning = false;
    }
    const uint16_t suffix = static_cast<uint16_t>(ESP.getEfuseMac());
    char hostname[24];
    snprintf(hostname, sizeof(hostname), "papergif-%04x", suffix);
    if (MDNS.begin(hostname)) {
        MDNS.addService("papergif-device", "tcp", 80);
        mdnsRunning = true;
        Serial.printf("Device service advertised as %s.local\n", hostname);
    }
}

void startWifiServer() {
    if (!wifiServerRunning) {
        configureWifiServer();
        wifiServer.begin();
        wifiServerRunning = true;
        Serial.println("Device profile server started");
    }
    advertiseDeviceService();
}

void stopWifiServer() {
    if (wifiServerRunning) {
        wifiServer.stop();
        wifiServerRunning = false;
    }
    if (mdnsRunning) {
        MDNS.end();
        mdnsRunning = false;
    }
}

void startWifiMode(bool showScreen = true) {
    if (wifiActive) {
        notifyWifiInfo();
        if (showScreen) {
            displayWifiMode();
        }
        return;
    }
    deepSleepSuspended = true;
    prepareWifiSsid();
    wifiApStarted = false;
    const bool hasRemote = remoteProfile != nullptr && remoteProfile->configured;
    const bool modeStarted = WiFi.mode(hasRemote ? WIFI_AP_STA : WIFI_AP);
    WiFi.setSleep(true);
    const bool accessPointStarted = modeStarted && WiFi.softAP(wifiSsid, kWifiPassword);
    const uint32_t startupDeadline = millis() + 3000;
    while (accessPointStarted && !wifiApStarted &&
           static_cast<int32_t>(millis() - startupDeadline) < 0) {
        delay(10);
    }
    if (!accessPointStarted || !wifiApStarted) {
        Serial.println("Wi-Fi AP failed to start");
        WiFi.softAPdisconnect(true);
        WiFi.mode(WIFI_OFF);
        wifiUploadFailed = true;
        deepSleepSuspended = false;
        notifyControl(kWifiFailed);
        if (showScreen) {
            displayWifiMode();
        }
        return;
    }
    wifiActive = true;
    startWifiServer();
    resetWifiUploadState();
    notifyWifiInfo();
    if (showScreen) {
        displayWifiMode();
    }
}

void closeWifiMode() {
    if (!wifiModeVisible) {
        return;
    }
    wifiModeVisible = false;
    displaySettings();
}

void stopWifiMode() {
    if (!wifiActive) {
        return;
    }
    const bool wasVisible = wifiModeVisible;
    if (upload.active) {
        cancelUpload(false);
        loadAnimation();
    }
    wifiApStopping = wifiApStarted;
    WiFi.softAPdisconnect(true);
    const bool hasRemote = remoteProfile != nullptr && remoteProfile->configured;
    WiFi.mode(hasRemote ? WIFI_STA : WIFI_OFF);
    if (!hasRemote || WiFi.status() != WL_CONNECTED) {
        stopWifiServer();
    }
    wifiActive = false;
    wifiModeVisible = false;
    deepSleepSuspended = false;
    if (wasVisible) {
        if (hasRemote) {
            displaySettings();
        } else {
            showLibrary();
        }
    }
    if (hasRemote) {
        connectHomeWifi();
    }
}

void beginUpload(const uint8_t* value, size_t length) {
    if (wifiActive || length < 9 || length > 9 + kMaximumTitleBytes) {
        notifyControl(kUploadFailed);
        return;
    }

    const uint32_t expectedBytes = readLittleEndian32(value + 1);
    if (expectedBytes < kHeaderBytes + sizeof(uint16_t) + kLegacyFrameBytes ||
        !sdHasSpaceFor(expectedBytes)) {
        notifyControl(kUploadFailed);
        return;
    }

    cancelUpload(false);
    closeAnimation();
    upload.file = SD.open(kTemporaryPath, FILE_WRITE);
    if (!upload.file) {
        loadAnimation();
        notifyControl(kUploadFailed);
        return;
    }

    upload.expectedBytes = expectedBytes;
    upload.expectedCrc = readLittleEndian32(value + 5);
    upload.receivedBytes = 0;
    upload.nextAcknowledgementAt = min(kUploadWindowBytes, expectedBytes);
    upload.runningCrc = UINT32_MAX;
    upload.lastActivityAt = millis();
    snprintf(upload.destinationPath, sizeof(upload.destinationPath),
        "%s/%08lX.pgif", kLibraryDirectory, static_cast<unsigned long>(upload.expectedCrc));
    size_t titleLength = 0;
    for (size_t index = 9; index < length && titleLength < kMaximumTitleBytes; ++index) {
        const uint8_t character = value[index];
        if (character >= 0x20 && character <= 0x7E) {
            upload.title[titleLength++] = static_cast<char>(character);
        }
    }
    while (titleLength > 0 && upload.title[titleLength - 1] == ' ') {
        --titleLength;
    }
    upload.title[titleLength] = '\0';
    if (titleLength == 0) {
        strlcpy(upload.title, "Untitled", sizeof(upload.title));
    }
    upload.active = true;
    finishRequested = false;
    libraryVisible = false;
    uploadScreenPending = true;
    notifyControl(kUploadReady);
}

void displayUploadStart() {
    M5.Display.setEpdMode(epd_mode_t::epd_quality);
    M5.Display.fillScreen(TFT_WHITE);
    M5.Display.setTextColor(TFT_BLACK, TFT_WHITE);
    M5.Display.setTextDatum(textdatum_t::top_left);

    M5.Display.setFont(&fonts::Orbitron_Light_32);
    M5.Display.setTextSize(1);
    M5.Display.drawString("RECEIVING", 36, 66);
    M5.Display.setFont(&fonts::FreeSans12pt7b);
    M5.Display.drawString("Keep paperGIF open", 38, 145);

    M5.Display.drawRect(36, 280, 468, 70, TFT_BLACK);
    M5.Display.setFont(&fonts::DejaVu56);
    M5.Display.drawCenterString("0%", kDisplayWidth / 2, 396);
    displayedUploadProgress = 0;
    pendingUploadProgress = 0;
    lastProgressDisplayAt = millis();
}

void displayUploadProgress(uint8_t progress) {
    if (progress <= displayedUploadProgress) {
        return;
    }

    M5.Display.setEpdMode(epd_mode_t::epd_fastest);
    const int32_t previousWidth = static_cast<int32_t>(displayedUploadProgress) * 452 / 100;
    const int32_t fillWidth = static_cast<int32_t>(progress) * 452 / 100;
    char percentage[8];
    snprintf(percentage, sizeof(percentage), "%u%%", progress);

    M5.Display.startWrite();
    M5.Display.fillRect(44 + previousWidth, 288, fillWidth - previousWidth, 54, TFT_BLACK);
    M5.Display.fillRect(80, 380, 380, 110, TFT_WHITE);
    M5.Display.setTextColor(TFT_BLACK, TFT_WHITE);
    M5.Display.setFont(&fonts::DejaVu56);
    M5.Display.setTextSize(1);
    M5.Display.drawCenterString(percentage, kDisplayWidth / 2, 396);
    M5.Display.endWrite();
    displayedUploadProgress = progress;
    lastProgressDisplayAt = millis();
}

void receiveData(const uint8_t* value, size_t length) {
    if (!upload.active || length == 0 ||
        length > upload.expectedBytes - upload.receivedBytes) {
        cancelUpload(true);
        loadAnimation();
        return;
    }

    if (upload.file.write(value, length) != length) {
        cancelUpload(true);
        loadAnimation();
        return;
    }
    upload.runningCrc = updateCrc32(upload.runningCrc, value, length);
    upload.receivedBytes += length;
    upload.lastActivityAt = millis();

    pendingUploadProgress = static_cast<uint8_t>(
        (static_cast<uint64_t>(upload.receivedBytes) * 100) / upload.expectedBytes);
    if (upload.receivedBytes >= upload.nextAcknowledgementAt) {
        notifyUploadProgress();
        upload.nextAcknowledgementAt = min(
            upload.expectedBytes,
            upload.nextAcknowledgementAt + kUploadWindowBytes);
    }
    if (upload.receivedBytes == upload.expectedBytes) {
        notifyControl(kUploadDataReceived);
        if (finishRequested) {
            completeUpload();
        }
    }
}

void completeUpload() {
    if (!upload.active || upload.receivedBytes != upload.expectedBytes) {
        return;
    }

    const uint32_t receivedCrc = upload.runningCrc ^ UINT32_MAX;
    const uint32_t expectedCrc = upload.expectedCrc;
    upload.file.flush();
    upload.file.close();
    upload.active = false;
    if (receivedCrc != expectedCrc || !installTemporaryAnimation()) {
        SD.remove(kTemporaryPath);
        loadAnimation();
        notifyControl(kUploadFailed);
        return;
    }
    notifyControl(kUploadComplete);
}

void finishUpload() {
    if (!upload.active) {
        notifyControl(kUploadFailed);
        return;
    }
    if (upload.receivedBytes != upload.expectedBytes) {
        finishRequested = true;
        return;
    }
    completeUpload();
}

void beginRemoteProfileUpload(const uint8_t* value, size_t length) {
    if (length != 9 || upload.active) {
        notifyControl(kUploadFailed);
        return;
    }
    const uint32_t expectedBytes = readLittleEndian32(value + 1);
    if (expectedBytes == 0 || expectedBytes > kMaximumRemoteProfileBytes ||
        !sdHasSpaceFor(expectedBytes)) {
        notifyControl(kUploadFailed);
        return;
    }

    cancelRemoteProfileUpload(false);
    remoteProfileUpload.file = SD.open(kRemoteProfileTemporaryPath, FILE_WRITE);
    if (!remoteProfileUpload.file) {
        notifyControl(kUploadFailed);
        return;
    }
    remoteProfileUpload.expectedBytes = expectedBytes;
    remoteProfileUpload.expectedCrc = readLittleEndian32(value + 5);
    remoteProfileUpload.nextAcknowledgementAt = min(kUploadWindowBytes, expectedBytes);
    remoteProfileUpload.runningCrc = UINT32_MAX;
    remoteProfileUpload.lastActivityAt = millis();
    remoteProfileUpload.active = true;
    notifyControl(kRemoteProfileReady);
}

void completeRemoteProfileUpload() {
    if (!remoteProfileUpload.active ||
        remoteProfileUpload.receivedBytes != remoteProfileUpload.expectedBytes) {
        return;
    }
    const uint32_t receivedCrc = remoteProfileUpload.runningCrc ^ UINT32_MAX;
    const uint32_t expectedCrc = remoteProfileUpload.expectedCrc;
    remoteProfileUpload.file.flush();
    remoteProfileUpload.file.close();
    remoteProfileUpload.active = false;
    if (receivedCrc != expectedCrc) {
        cancelRemoteProfileUpload(false);
        notifyControl(kUploadFailed);
        return;
    }
    if (!installTemporaryRemoteProfile()) {
        cancelRemoteProfileUpload(false);
        notifyControl(kUploadFailed);
        return;
    }
    notifyControl(kRemoteProfileComplete);
}

void finishRemoteProfileUpload() {
    if (!remoteProfileUpload.active) {
        notifyControl(kUploadFailed);
    } else if (remoteProfileUpload.receivedBytes == remoteProfileUpload.expectedBytes) {
        completeRemoteProfileUpload();
    } else {
        remoteProfileUpload.finishRequested = true;
    }
}

void receiveRemoteProfileData(const uint8_t* value, size_t length) {
    if (!remoteProfileUpload.active || length == 0 ||
        length > remoteProfileUpload.expectedBytes - remoteProfileUpload.receivedBytes ||
        remoteProfileUpload.file.write(value, length) != length) {
        cancelRemoteProfileUpload(true);
        return;
    }
    remoteProfileUpload.runningCrc = updateCrc32(remoteProfileUpload.runningCrc, value, length);
    remoteProfileUpload.receivedBytes += length;
    remoteProfileUpload.lastActivityAt = millis();
    if (remoteProfileUpload.receivedBytes >= remoteProfileUpload.nextAcknowledgementAt) {
        notifyRemoteProfileProgress();
        remoteProfileUpload.nextAcknowledgementAt = min(
            remoteProfileUpload.expectedBytes,
            remoteProfileUpload.nextAcknowledgementAt + kUploadWindowBytes);
    }
    if (remoteProfileUpload.receivedBytes == remoteProfileUpload.expectedBytes) {
        notifyControl(kRemoteProfileDataReceived);
        if (remoteProfileUpload.finishRequested) {
            completeRemoteProfileUpload();
        }
    }
}

class ControlCallbacks final : public NimBLECharacteristicCallbacks {
    void onWrite(NimBLECharacteristic* characteristic, NimBLEConnInfo&) override {
        const NimBLEAttValue value = characteristic->getValue();
        if (value.size() == 0) {
            notifyControl(kUploadFailed);
            return;
        }
        if (value[0] == kBeginUpload) {
            beginUpload(value.data(), value.size());
        } else if (value[0] == kFinishUpload && value.size() == 1) {
            finishUpload();
        } else if (value[0] == kListLibrary && value.size() == 1) {
            notifyLibraryCount();
        } else if (value[0] == kReadLibraryItem && value.size() == 2) {
            notifyLibraryItem(value[1]);
        } else if (value[0] == kDeleteLibraryItem && value.size() == 2) {
            const uint8_t response[] = {
                kLibraryItemDeleted,
                value[1],
                deleteLibraryItem(value[1]) ? static_cast<uint8_t>(1) : static_cast<uint8_t>(0),
            };
            controlCharacteristic->setValue(response, sizeof(response));
            controlCharacteristic->notify();
        } else if (value[0] == kSelectLibraryItem && value.size() == 2) {
            if (value[1] < libraryItemCount && loadAnimation(libraryItems[value[1]].path)) {
                persistActiveSelection();
                displayCurrentFrame();
            } else {
                notifyControl(kUploadFailed);
            }
        } else if (value[0] == kStartWifi && value.size() == 1) {
            wifiStartRequested = true;
            wifiStartRequestedAt = millis();
        } else if (value[0] == kRequestHomeWifiStatus && value.size() == 1) {
            notifyHomeWifiStatus();
        } else if (value[0] == kPrepareWifiUpload && value.size() == 1 &&
                   homeWifiState == 2 && !upload.active) {
            bluetoothSuspendRequested = true;
            bluetoothSuspendRequestedAt = millis();
        } else if (value[0] == kScanWifiNetworks && value.size() == 1) {
            wifiScanRequested = true;
        } else if (value[0] == kReadWifiNetwork && value.size() == 2) {
            notifyWifiNetwork(value[1]);
        } else if (value[0] == kBeginRemoteProfile && value.size() == 9) {
            beginRemoteProfileUpload(value.data(), value.size());
        } else if (value[0] == kFinishRemoteProfile && value.size() == 1) {
            finishRemoteProfileUpload();
        } else {
            notifyControl(kUploadFailed);
        }
    }
};

class DataCallbacks final : public NimBLECharacteristicCallbacks {
    void onWrite(NimBLECharacteristic* characteristic, NimBLEConnInfo&) override {
        const NimBLEAttValue value = characteristic->getValue();
        if (remoteProfileUpload.active) {
            receiveRemoteProfileData(value.data(), value.size());
        } else {
            receiveData(value.data(), value.size());
        }
    }
};

class ServerCallbacks final : public NimBLEServerCallbacks {
    void onConnect(NimBLEServer* server, NimBLEConnInfo& connectionInfo) override {
        Serial.println("BLE connected");
        server->updateConnParams(connectionInfo.getConnHandle(), 12, 12, 0, 200);
        deviceConnected = true;
        stillFrameDisplayed = false;
        nextFrameAt = millis();
    }

    void onDisconnect(NimBLEServer*, NimBLEConnInfo&, int reason) override {
        Serial.printf("BLE disconnected, reason: %d\n", reason);
        deviceConnected = false;
        if (bluetoothStopping) {
            return;
        }
        if (upload.active) {
            cancelUpload(false);
            loadAnimation();
        }
        if (remoteProfileUpload.active) {
            cancelRemoteProfileUpload(false);
        }
        splashPending = !animationReady;
        NimBLEDevice::startAdvertising();
    }
};

ControlCallbacks controlCallbacks;
DataCallbacks dataCallbacks;
ServerCallbacks serverCallbacks;

void startBluetooth() {
    if (bluetoothActive) {
        return;
    }
    NimBLEDevice::init("paperGIF");
    NimBLEDevice::setMTU(517);
    NimBLEServer* server = NimBLEDevice::createServer();
    server->setCallbacks(&serverCallbacks, false);
    server->advertiseOnDisconnect(true);

    NimBLEService* service = server->createService(kServiceUuid);
    controlCharacteristic = service->createCharacteristic(
        kControlUuid, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::NOTIFY, 64);
    NimBLECharacteristic* dataCharacteristic = service->createCharacteristic(
        kDataUuid, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR, 512);
    controlCharacteristic->setCallbacks(&controlCallbacks);
    dataCharacteristic->setCallbacks(&dataCallbacks);
    server->start();

    NimBLEAdvertising* advertising = NimBLEDevice::getAdvertising();
    advertising->addServiceUUID(kServiceUuid);
    advertising->setPreferredParams(12, 12);
    advertising->enableScanResponse(true);
    advertising->start();
    bluetoothActive = true;
}

void suspendBluetoothForWifiUpload() {
    bluetoothSuspendRequested = false;
    bluetoothStopping = true;
    const bool stopped = NimBLEDevice::deinit(true);
    bluetoothStopping = false;
    if (!stopped) {
        Serial.println("Could not suspend Bluetooth for Wi-Fi upload");
        return;
    }
    bluetoothActive = false;
    deviceConnected = false;
    controlCharacteristic = nullptr;
    bluetoothSuspendedForWifiUpload = true;
    bluetoothSuspendedAt = millis();
    WiFi.setSleep(false);
    Serial.println("Bluetooth suspended for Wi-Fi upload");
}

void resumeBluetoothAfterWifiUpload() {
    bluetoothResumeRequested = false;
    if (!bluetoothSuspendedForWifiUpload) {
        return;
    }
    WiFi.setSleep(true);
    bluetoothSuspendedForWifiUpload = false;
    startBluetooth();
    Serial.println("Bluetooth resumed after Wi-Fi upload");
}

void displayDisconnectedSplash() {
    M5.Display.setEpdMode(epd_mode_t::epd_quality);
    M5.Display.fillScreen(TFT_WHITE);

    M5.Display.setTextColor(TFT_BLACK, TFT_WHITE);
    M5.Display.setTextDatum(textdatum_t::top_left);

    M5.Display.fillRect(0, 0, kDisplayWidth, 20, TFT_BLACK);
    M5.Display.setFont(&fonts::Yellowtail_32);
    M5.Display.setTextSize(1);
    M5.Display.drawString("paperGIF", 40, 68);

    M5.Display.drawFastHLine(40, 190, 460, TFT_BLACK);

    M5.Display.setFont(&fonts::Orbitron_Light_24);
    M5.Display.drawString(deviceConnected ? "IPHONE CONNECTED" : "READY TO CONNECT", 40, 242);

    M5.Display.setFont(&fonts::FreeSans18pt7b);
    M5.Display.drawString("Open paperGIF", 42, 338);
    M5.Display.drawString("on your iPhone", 42, 388);

    M5.Display.drawCircle(60, 720, 18, TFT_BLACK);
    M5.Display.fillCircle(60, 720, 7, TFT_BLACK);
    M5.Display.setFont(&fonts::FreeMonoBold12pt7b);
    M5.Display.drawString("BLUETOOTH ON", 96, 704);
    M5.Display.drawString(sdReady ? "SD CARD READY" : "SD CARD UNAVAILABLE", 42, 790);

    M5.Display.fillRect(0, 940, kDisplayWidth, 20, TFT_BLACK);
    splashPending = false;
}

void displayLibrary() {
    refreshLibrary();
    if (libraryItemCount > 0) {
        librarySelection = min(librarySelection, libraryItemCount - 1);
    }
    M5.Display.setEpdMode(epd_mode_t::epd_quality);
    M5.Display.startWrite();
    M5.Display.fillScreen(TFT_WHITE);
    M5.Display.setTextColor(TFT_BLACK, TFT_WHITE);
    M5.Display.setTextDatum(textdatum_t::top_left);

    M5.Display.setFont(&fonts::Orbitron_Light_32);
    M5.Display.setTextSize(1);
    M5.Display.drawString("LIBRARY", 32, 38);
    M5.Display.setFont(&fonts::FreeSansBold24pt7b);
    M5.Display.drawString("X", 476, 40);
    M5.Display.drawFastHLine(32, 98, 476, TFT_BLACK);
    M5.Display.setFont(&fonts::FreeSans12pt7b);
    M5.Display.drawString(
        recoveredFromRenderCrash ? "Last item stopped while displaying" : "Tap an item to play",
        34, 116);

    const size_t firstItem = libraryPage * kLibraryRowsPerPage;
    const size_t visibleItems = min(kLibraryRowsPerPage, libraryItemCount - min(firstItem, libraryItemCount));
    for (size_t row = 0; row < visibleItems; ++row) {
        drawLibraryRow(firstItem + row, false);
    }

    if (libraryItemCount == 0) {
        M5.Display.setFont(&fonts::FreeSansBold18pt7b);
        M5.Display.drawCenterString("No stored media", kDisplayWidth / 2, 390);
    }

    const size_t pageCount = max(static_cast<size_t>(1),
        (libraryItemCount + kLibraryRowsPerPage - 1) / kLibraryRowsPerPage);
    M5.Display.drawRect(30, 846, 140, 68, TFT_BLACK);
    M5.Display.setFont(&fonts::FreeSansBold9pt7b);
    M5.Display.drawCenterString("PREVIOUS", 100, 866);
    M5.Display.drawRect(370, 846, 140, 68, TFT_BLACK);
    M5.Display.drawCenterString("NEXT", 440, 866);
    char pageText[20];
    snprintf(pageText, sizeof(pageText), "%u / %u",
        static_cast<unsigned>(libraryPage + 1), static_cast<unsigned>(pageCount));
    M5.Display.setFont(&fonts::FreeMono12pt7b);
    M5.Display.drawCenterString(pageText, kDisplayWidth / 2, 864);
    M5.Display.endWrite();
    remoteVisible = false;
    libraryVisible = true;
    settingsVisible = false;
    slideshowMenuVisible = false;
    wifiModeVisible = false;
}

void drawSettingsRow(const char* title, const char* detail, int32_t y) {
    M5.Display.drawRect(32, y, 476, 142, TFT_BLACK);
    M5.Display.setFont(&fonts::FreeSansBold18pt7b);
    M5.Display.drawString(title, 54, y + 34);
    M5.Display.setFont(&fonts::FreeSans12pt7b);
    M5.Display.drawString(detail, 54, y + 86);
    M5.Display.setFont(&fonts::FreeSansBold18pt7b);
    M5.Display.drawString(">", 466, y + 48);
}

void displaySettings() {
    M5.Display.setEpdMode(epd_mode_t::epd_quality);
    M5.Display.startWrite();
    M5.Display.fillScreen(TFT_WHITE);
    M5.Display.setTextColor(TFT_BLACK, TFT_WHITE);
    M5.Display.setTextDatum(textdatum_t::top_left);
    M5.Display.setFont(&fonts::Orbitron_Light_32);
    M5.Display.setTextSize(1);
    M5.Display.drawString("SETTINGS", 32, 38);
    M5.Display.setFont(&fonts::FreeSansBold24pt7b);
    M5.Display.drawString("X", 476, 40);
    M5.Display.drawFastHLine(32, 98, 476, TFT_BLACK);

    drawSettingsRow("LIBRARY", "Choose stored screen saver media", 150);
    drawSettingsRow("SCREEN SAVER", "Playback and interval options", 312);
    drawSettingsRow("WI-FI TRANSFER", wifiActive ? "Transfer network is active" : "Start transfer network", 474);

    M5.Display.setFont(&fonts::FreeSans12pt7b);
    M5.Display.drawString("Remote layout is configured in the iPhone app.", 34, 700);
    M5.Display.endWrite();
    settingsVisible = true;
    remoteVisible = false;
    libraryVisible = false;
    slideshowMenuVisible = false;
    wifiModeVisible = false;
    deepSleepSuspended = true;
}

void drawToggleRow(const char* label, bool enabled, int32_t y) {
    M5.Display.drawRect(32, y, 476, 104, TFT_BLACK);
    M5.Display.setFont(&fonts::FreeSansBold12pt7b);
    M5.Display.drawString(label, 54, y + 34);
    M5.Display.drawRect(400, y + 25, 78, 54, TFT_BLACK);
    if (enabled) {
        M5.Display.fillRect(405, y + 30, 68, 44, TFT_BLACK);
    }
    M5.Display.setTextColor(enabled ? TFT_WHITE : TFT_BLACK, enabled ? TFT_BLACK : TFT_WHITE);
    M5.Display.setFont(&fonts::FreeSansBold9pt7b);
    M5.Display.drawCenterString(enabled ? "ON" : "OFF", 439, y + 40);
    M5.Display.setTextColor(TFT_BLACK, TFT_WHITE);
}

void formatDuration(uint32_t seconds, char* text, size_t capacity) {
    if (seconds < 60) {
        snprintf(text, capacity, "%lu SEC", static_cast<unsigned long>(seconds));
    } else {
        snprintf(text, capacity, "%lu MIN", static_cast<unsigned long>(seconds / 60));
    }
}

void formatSlideshowInterval(char* text, size_t capacity) {
    formatDuration(slideshowIntervalSeconds(), text, capacity);
}

void formatScreensaverDelay(char* text, size_t capacity) {
    formatDuration(screensaverDelaySeconds(), text, capacity);
}

void adjustScreensaverDelay(int direction) {
    const uint32_t currentSeconds = screensaverDelaySeconds();
    int nextIndex = -1;
    if (direction < 0) {
        for (int index = static_cast<int>(kSlideshowIntervalCount) - 1; index >= 0; --index) {
            if (kSlideshowIntervalsSeconds[index] < currentSeconds) {
                nextIndex = index;
                break;
            }
        }
    } else {
        for (size_t index = 0; index < kSlideshowIntervalCount; ++index) {
            if (kSlideshowIntervalsSeconds[index] > currentSeconds) {
                nextIndex = static_cast<int>(index);
                break;
            }
        }
    }
    if (nextIndex < 0) {
        return;
    }
    screensaverDelayIndex = static_cast<uint8_t>(nextIndex);
    persistSettings();
    displaySlideshowMenu();
}

void adjustSlideshowInterval(int direction) {
    if (direction < 0 && slideshowIntervalIndex > 0) {
        --slideshowIntervalIndex;
    } else if (direction > 0 && slideshowIntervalIndex + 1 < kSlideshowIntervalCount) {
        ++slideshowIntervalIndex;
    } else {
        return;
    }
    persistSettings();
    displaySlideshowMenu();
}

void displaySlideshowMenu() {
    M5.Display.setEpdMode(epd_mode_t::epd_quality);
    M5.Display.startWrite();
    M5.Display.fillScreen(TFT_WHITE);
    M5.Display.setTextColor(TFT_BLACK, TFT_WHITE);
    M5.Display.setTextDatum(textdatum_t::top_left);
    M5.Display.setFont(&fonts::Orbitron_Light_24);
    M5.Display.setTextSize(1);
    M5.Display.drawString("SCREEN SAVER", 32, 42);
    M5.Display.setFont(&fonts::FreeSansBold24pt7b);
    M5.Display.drawString("X", 476, 40);
    M5.Display.drawFastHLine(32, 98, 476, TFT_BLACK);

    drawToggleRow("ENABLED", slideshowEnabled, 130);
    drawToggleRow("SLEEP BETWEEN IMAGES", slideshowDeepSleep, 250);

    M5.Display.drawRect(32, 370, 476, 104, TFT_BLACK);
    M5.Display.setFont(&fonts::FreeSansBold12pt7b);
    M5.Display.drawString("START AFTER", 54, 404);
    M5.Display.drawRect(274, 395, 54, 54, TFT_BLACK);
    M5.Display.drawCenterString("-", 301, 408);
    char delayText[16];
    formatScreensaverDelay(delayText, sizeof(delayText));
    M5.Display.setFont(&fonts::FreeMonoBold12pt7b);
    M5.Display.drawCenterString(delayText, 374, 408);
    M5.Display.drawRect(448, 395, 54, 54, TFT_BLACK);
    M5.Display.drawCenterString("+", 475, 408);

    M5.Display.drawRect(32, 490, 476, 104, TFT_BLACK);
    M5.Display.setFont(&fonts::FreeSansBold12pt7b);
    M5.Display.drawString("IMAGE INTERVAL", 54, 524);
    M5.Display.drawRect(274, 515, 54, 54, TFT_BLACK);
    M5.Display.drawCenterString("-", 301, 528);
    char intervalText[16];
    formatSlideshowInterval(intervalText, sizeof(intervalText));
    M5.Display.setFont(&fonts::FreeMonoBold12pt7b);
    M5.Display.drawCenterString(intervalText, 374, 528);
    M5.Display.drawRect(448, 515, 54, 54, TFT_BLACK);
    M5.Display.drawCenterString("+", 475, 528);

    M5.Display.setFont(&fonts::FreeSans12pt7b);
    M5.Display.drawString("Sleep keeps the current image visible", 34, 650);
    M5.Display.drawString("and turns off Bluetooth between images.", 34, 690);
    M5.Display.setFont(&fonts::FreeMonoBold12pt7b);
    M5.Display.drawString("PRESS CENTER BUTTON TO WAKE", 34, 800);
    M5.Display.endWrite();
    remoteVisible = false;
    libraryVisible = false;
    settingsVisible = false;
    slideshowMenuVisible = true;
    deepSleepSuspended = true;
}

void displayWifiMode() {
    M5.Display.setEpdMode(epd_mode_t::epd_quality);
    M5.Display.startWrite();
    M5.Display.fillScreen(TFT_WHITE);
    M5.Display.setTextColor(TFT_BLACK, TFT_WHITE);
    M5.Display.setTextDatum(textdatum_t::top_left);
    M5.Display.setFont(&fonts::Orbitron_Light_24);
    M5.Display.setTextSize(1);
    M5.Display.drawString("WIFI TRANSFER", 32, 42);
    M5.Display.setFont(&fonts::FreeSansBold24pt7b);
    M5.Display.drawString("X", 476, 40);
    M5.Display.drawFastHLine(32, 98, 476, TFT_BLACK);

    if ((WiFi.getMode() & WIFI_AP) == 0) {
        M5.Display.setFont(&fonts::FreeSansBold18pt7b);
        M5.Display.drawCenterString("Wi-Fi could not start", kDisplayWidth / 2, 350);
        M5.Display.setFont(&fonts::FreeSans12pt7b);
        M5.Display.drawCenterString("Tap X to return", kDisplayWidth / 2, 420);
    } else {
        char qrText[96];
        snprintf(qrText, sizeof(qrText), "WIFI:T:WPA;S:%s;P:%s;;", wifiSsid, kWifiPassword);
        M5.Display.qrcode(qrText, 110, 130, 320, 6, true);

        M5.Display.setFont(&fonts::FreeSans12pt7b);
        M5.Display.drawString("NETWORK", 42, 500);
        M5.Display.drawString("PASSWORD", 42, 562);
        M5.Display.drawString("DEVICE", 42, 624);
        M5.Display.setFont(&fonts::FreeMonoBold12pt7b);
        M5.Display.drawString(wifiSsid, 188, 500);
        M5.Display.drawString(kWifiPassword, 188, 562);
        M5.Display.drawString("192.168.4.1", 188, 624);
        M5.Display.setFont(&fonts::FreeSans12pt7b);
        M5.Display.drawString("Scan to join, then return to paperGIF.", 42, 700);
        M5.Display.drawString("The app detects Wi-Fi automatically.", 42, 740);

        if (wifiUploadSucceeded || wifiUploadFailed) {
            M5.Display.drawFastHLine(42, 810, 456, TFT_BLACK);
            M5.Display.setFont(&fonts::FreeSansBold12pt7b);
            M5.Display.drawString(
                wifiUploadSucceeded ? "UPLOAD COMPLETE" : "UPLOAD FAILED - TRY AGAIN",
                42,
                842);
        }
    }
    M5.Display.endWrite();
    remoteVisible = false;
    libraryVisible = false;
    settingsVisible = false;
    slideshowMenuVisible = false;
    wifiModeVisible = true;
    deepSleepSuspended = true;
}

struct RemoteControlFrame {
    int32_t x;
    int32_t y;
    int32_t width;
    int32_t height;
};

bool remoteControlFrame(const RemotePage& page, size_t targetIndex, RemoteControlFrame& frame) {
    constexpr int32_t left = 24;
    constexpr int32_t top = 142;
    constexpr int32_t gap = 12;
    constexpr int32_t width = 240;
    constexpr int32_t halfHeight = 77;
    bool occupied[8][2] = {};
    bool placed[kMaximumRemoteControls] = {};
    RemoteControlFrame frames[kMaximumRemoteControls] = {};

    auto place = [&](size_t index, uint8_t row, uint8_t column) {
        const RemoteControl& control = page.controls[index];
        const uint8_t rowSpan = control.gridHeight;
        const uint8_t columnSpan = control.gridWidth;
        if (columnSpan == 2) {
            column = 0;
        }
        if (column >= 2 || column + columnSpan > 2 || row + rowSpan > 8) {
            return false;
        }
        for (uint8_t offset = 0; offset < rowSpan; ++offset) {
            for (uint8_t columnOffset = 0; columnOffset < columnSpan; ++columnOffset) {
                if (occupied[row + offset][column + columnOffset]) {
                    return false;
                }
            }
        }
        for (uint8_t offset = 0; offset < rowSpan; ++offset) {
            for (uint8_t columnOffset = 0; columnOffset < columnSpan; ++columnOffset) {
                occupied[row + offset][column + columnOffset] = true;
            }
        }
        frames[index] = {
            left + column * (width + gap),
            top + row * (halfHeight + gap),
            width * columnSpan + gap * (columnSpan - 1),
            halfHeight * rowSpan + gap * (rowSpan - 1)};
        placed[index] = true;
        return true;
    };

    for (size_t index = 0; index < page.controlCount; ++index) {
        const int8_t slot = page.controls[index].layoutSlot;
        if (slot >= 0 && slot < 16) {
            place(index, slot / 2, slot % 2);
        }
    }

    for (size_t index = 0; index < page.controlCount; ++index) {
        if (placed[index]) {
            continue;
        }
        for (uint8_t row = 0; row < 8 && !placed[index]; ++row) {
            for (uint8_t column = 0; column < 2 && !placed[index]; ++column) {
                if (place(index, row, column)) {
                    break;
                }
            }
        }
        if (!placed[index]) {
            return false;
        }
    }
    if (targetIndex >= page.controlCount || !placed[targetIndex]) {
        return false;
    }
    frame = frames[targetIndex];
    return true;
}

void drawRemoteControlIcon(
    const char* symbol,
    const uint8_t* iconBitmap,
    uint8_t iconDimension,
    int32_t centerX,
    int32_t centerY,
    int32_t size,
    uint32_t foreground,
    uint32_t background) {
    if (iconBitmap != nullptr) {
        const int32_t left = centerX - size / 2;
        const int32_t top = centerY - size / 2;
        for (int32_t destinationY = 0; destinationY < size; ++destinationY) {
            const int32_t sourceTop = destinationY * iconDimension / size;
            const int32_t sourceBottom = max(
                sourceTop + 1,
                (destinationY + 1) * iconDimension / size);
            for (int32_t destinationX = 0; destinationX < size; ++destinationX) {
                const int32_t sourceLeft = destinationX * iconDimension / size;
                const int32_t sourceRight = max(
                    sourceLeft + 1,
                    (destinationX + 1) * iconDimension / size);
                uint8_t blackPixels = 0;
                uint8_t pixelCount = 0;
                for (int32_t sourceY = sourceTop; sourceY < sourceBottom; ++sourceY) {
                    for (int32_t sourceX = sourceLeft; sourceX < sourceRight; ++sourceX) {
                        const uint8_t byte = iconBitmap[
                            sourceY * (iconDimension / 8) + sourceX / 8];
                        blackPixels += (byte & (0x80 >> (sourceX % 8))) != 0;
                        ++pixelCount;
                    }
                }
                if (blackPixels * 2 >= pixelCount) {
                    M5.Display.drawPixel(left + destinationX, top + destinationY, foreground);
                }
            }
        }
        return;
    }
    if (symbol[0] == '\0') {
        return;
    }
    const int32_t half = size / 2;
    const int32_t quarter = max(2, size / 4);
    if (strcmp(symbol, "circle.fill") == 0) {
        M5.Display.fillCircle(centerX, centerY, half, foreground);
    } else if (strcmp(symbol, "play.fill") == 0) {
        M5.Display.fillTriangle(centerX - half, centerY - half, centerX - half,
            centerY + half, centerX + half, centerY, foreground);
    } else if (strcmp(symbol, "pause.fill") == 0) {
        M5.Display.fillRect(centerX - half, centerY - half, quarter, size, foreground);
        M5.Display.fillRect(centerX + half - quarter, centerY - half, quarter, size, foreground);
    } else if (strcmp(symbol, "playpause.fill") == 0) {
        const int32_t barWidth = max(2, size / 8);
        const int32_t firstBarX = centerX + max(2, size / 10);
        const int32_t secondBarX = centerX + half - barWidth;
        M5.Display.fillTriangle(centerX - half, centerY - half, centerX - half,
            centerY + half, centerX - 2, centerY, foreground);
        M5.Display.fillRect(firstBarX, centerY - half, barWidth, size, foreground);
        M5.Display.fillRect(secondBarX, centerY - half, barWidth, size, foreground);
    } else if (strcmp(symbol, "stop.fill") == 0) {
        M5.Display.fillRect(centerX - half, centerY - half, size, size, foreground);
    } else if (strcmp(symbol, "backward.fill") == 0 || strcmp(symbol, "forward.fill") == 0) {
        const bool forward = symbol[0] == 'f';
        if (forward) {
            M5.Display.fillTriangle(centerX - half, centerY - half,
                centerX - half, centerY + half, centerX, centerY, foreground);
            M5.Display.fillTriangle(centerX, centerY - half,
                centerX, centerY + half, centerX + half, centerY, foreground);
        } else {
            M5.Display.fillTriangle(centerX - half, centerY,
                centerX, centerY - half, centerX, centerY + half, foreground);
            M5.Display.fillTriangle(centerX, centerY,
                centerX + half, centerY - half, centerX + half, centerY + half, foreground);
        }
    } else if (strncmp(symbol, "speaker", 7) == 0) {
        M5.Display.fillRect(centerX - half, centerY - quarter, quarter, quarter * 2, foreground);
        M5.Display.fillTriangle(centerX - quarter, centerY - quarter,
            centerX + quarter, centerY - half,
            centerX + quarter, centerY + half, foreground);
        if (strcmp(symbol, "speaker.wave.2.fill") == 0) {
            M5.Display.drawArc(centerX + quarter, centerY, half, half - 2, -50, 50, foreground);
        } else if (strcmp(symbol, "speaker.slash.fill") == 0) {
            M5.Display.drawLine(centerX - half, centerY - half, centerX + half, centerY + half, foreground);
            M5.Display.drawLine(centerX - half + 1, centerY - half, centerX + half + 1, centerY + half, foreground);
        }
    } else if (strcmp(symbol, "power") == 0) {
        M5.Display.drawCircle(centerX, centerY + 2, half - 2, foreground);
        M5.Display.drawCircle(centerX, centerY + 2, half - 3, foreground);
        M5.Display.fillRect(centerX - 2, centerY - half, 5, half + 2, background);
        M5.Display.fillRect(centerX - 1, centerY - half, 3, half + 2, foreground);
    } else if (strcmp(symbol, "lightbulb.fill") == 0) {
        M5.Display.fillCircle(centerX, centerY - 3, half - 3, foreground);
        M5.Display.fillRect(centerX - quarter, centerY + quarter, quarter * 2, quarter, foreground);
        M5.Display.drawFastHLine(centerX - quarter, centerY + half, quarter * 2, foreground);
    } else if (strcmp(symbol, "sun.max.fill") == 0) {
        M5.Display.fillCircle(centerX, centerY, quarter, foreground);
        for (uint8_t index = 0; index < 8; ++index) {
            const float angle = index * PI / 4;
            M5.Display.drawLine(centerX + cos(angle) * (quarter + 3), centerY + sin(angle) * (quarter + 3),
                centerX + cos(angle) * half, centerY + sin(angle) * half, foreground);
        }
    } else if (strcmp(symbol, "moon.fill") == 0) {
        M5.Display.fillCircle(centerX, centerY, half, foreground);
        M5.Display.fillCircle(centerX + quarter, centerY - quarter, half - 2, background);
    } else if (strcmp(symbol, "sparkles") == 0) {
        M5.Display.drawFastHLine(centerX - half, centerY, size, foreground);
        M5.Display.drawFastVLine(centerX, centerY - half, size, foreground);
        M5.Display.drawFastHLine(centerX + quarter, centerY - quarter, half, foreground);
        M5.Display.drawFastVLine(centerX + half, centerY - half, half, foreground);
    } else if (strcmp(symbol, "house.fill") == 0) {
        M5.Display.fillTriangle(centerX - half, centerY, centerX, centerY - half,
            centerX + half, centerY, foreground);
        M5.Display.fillRect(centerX - half + 3, centerY, size - 6, half, foreground);
    } else if (strcmp(symbol, "gearshape.fill") == 0) {
        M5.Display.fillCircle(centerX, centerY, half, foreground);
        M5.Display.fillCircle(centerX, centerY, quarter, background);
        for (uint8_t index = 0; index < 8; ++index) {
            const float angle = index * PI / 4;
            M5.Display.drawLine(
                centerX + cos(angle) * (half - 1), centerY + sin(angle) * (half - 1),
                centerX + cos(angle) * (half + 3), centerY + sin(angle) * (half + 3),
                foreground);
        }
    } else if (strncmp(symbol, "arrow.", 6) == 0) {
        if (strcmp(symbol, "arrow.up") == 0 || strcmp(symbol, "arrow.down") == 0) {
            const int32_t direction = strcmp(symbol, "arrow.up") == 0 ? -1 : 1;
            const int32_t tipY = centerY + direction * half;
            M5.Display.drawFastVLine(centerX, centerY - half, size + 1, foreground);
            M5.Display.drawLine(centerX, tipY, centerX - quarter, tipY - direction * quarter, foreground);
            M5.Display.drawLine(centerX, tipY, centerX + quarter, tipY - direction * quarter, foreground);
        } else {
            const int32_t direction = strcmp(symbol, "arrow.left") == 0 ? -1 : 1;
            const int32_t tipX = centerX + direction * half;
            M5.Display.drawFastHLine(centerX - half, centerY, size + 1, foreground);
            M5.Display.drawLine(tipX, centerY, tipX - direction * quarter, centerY - quarter, foreground);
            M5.Display.drawLine(tipX, centerY, tipX - direction * quarter, centerY + quarter, foreground);
        }
    } else if (strcmp(symbol, "plus") == 0 || strcmp(symbol, "minus") == 0 ||
               strcmp(symbol, "xmark") == 0 || strcmp(symbol, "checkmark") == 0) {
        if (strcmp(symbol, "plus") == 0) {
            M5.Display.drawFastHLine(centerX - half, centerY, size, foreground);
            M5.Display.drawFastVLine(centerX, centerY - half, size, foreground);
        } else if (strcmp(symbol, "minus") == 0) {
            M5.Display.drawFastHLine(centerX - half, centerY, size, foreground);
        } else if (strcmp(symbol, "checkmark") == 0) {
            M5.Display.drawLine(centerX - half, centerY, centerX - quarter, centerY + half, foreground);
            M5.Display.drawLine(centerX - quarter, centerY + half, centerX + half, centerY - half, foreground);
        } else {
            M5.Display.drawLine(centerX - half, centerY - half, centerX + half, centerY + half, foreground);
            M5.Display.drawLine(centerX - half, centerY + half, centerX + half, centerY - half, foreground);
        }
    } else if (strcmp(symbol, "heart.fill") == 0) {
        M5.Display.fillCircle(centerX - quarter, centerY - quarter, quarter + 1, foreground);
        M5.Display.fillCircle(centerX + quarter, centerY - quarter, quarter + 1, foreground);
        M5.Display.fillTriangle(centerX - half, centerY - quarter, centerX + half,
            centerY - quarter, centerX, centerY + half, foreground);
    } else if (strcmp(symbol, "star.fill") == 0) {
        for (uint8_t index = 0; index < 10; ++index) {
            const float firstAngle = -PI / 2 + index * PI / 5;
            const float secondAngle = -PI / 2 + (index + 1) * PI / 5;
            const int32_t firstRadius = index % 2 == 0 ? half : quarter;
            const int32_t secondRadius = index % 2 == 0 ? quarter : half;
            M5.Display.fillTriangle(centerX, centerY,
                centerX + cos(firstAngle) * firstRadius,
                centerY + sin(firstAngle) * firstRadius,
                centerX + cos(secondAngle) * secondRadius,
                centerY + sin(secondAngle) * secondRadius,
                foreground);
        }
    } else if (strcmp(symbol, "bolt.fill") == 0) {
        M5.Display.fillTriangle(centerX + quarter, centerY - half,
            centerX - half, centerY + 1, centerX + 1, centerY, foreground);
        M5.Display.fillTriangle(centerX - 1, centerY,
            centerX + half, centerY - 1, centerX - quarter, centerY + half, foreground);
    } else if (strcmp(symbol, "lock.fill") == 0) {
        M5.Display.drawRoundRect(centerX - quarter, centerY - half, quarter * 2,
            half + 4, quarter, foreground);
        M5.Display.fillRect(centerX - half, centerY - 2, size, half + 4, foreground);
    } else if (strcmp(symbol, "wifi") == 0) {
        M5.Display.drawArc(centerX, centerY + half, half, half - 2, 220, 320, foreground);
        M5.Display.drawArc(centerX, centerY + half, quarter + 2, quarter, 220, 320, foreground);
        M5.Display.fillCircle(centerX, centerY + half - 1, 2, foreground);
    } else if (strcmp(symbol, "slider.horizontal.3") == 0) {
        for (int32_t offset = -quarter; offset <= quarter; offset += quarter) {
            M5.Display.drawFastHLine(centerX - half, centerY + offset, size, foreground);
        }
        M5.Display.fillCircle(centerX - quarter, centerY - quarter, 2, foreground);
        M5.Display.fillCircle(centerX + quarter, centerY, 2, foreground);
        M5.Display.fillCircle(centerX, centerY + quarter, 2, foreground);
    } else if (strcmp(symbol, "music.note") == 0) {
        M5.Display.drawFastVLine(centerX + quarter, centerY - half, size - quarter, foreground);
        M5.Display.drawFastHLine(centerX - quarter, centerY - half, half, foreground);
        M5.Display.fillCircle(centerX, centerY + half - 2, quarter, foreground);
    } else if (strcmp(symbol, "display") == 0) {
        M5.Display.drawRect(centerX - half, centerY - half, size, size - quarter, foreground);
        M5.Display.drawFastVLine(centerX, centerY + quarter, quarter, foreground);
        M5.Display.drawFastHLine(centerX - quarter, centerY + half, half, foreground);
    }
}

bool layoutRemoteText(
    const char* text,
    int32_t x,
    int32_t y,
    int32_t width,
    int32_t height,
    uint8_t horizontalAlignment,
    uint8_t verticalAlignment,
    bool draw) {
    const int32_t lineHeight = M5.Display.fontHeight() + 4;
    if (lineHeight > height) {
        return false;
    }
    int16_t lineWidths[193] = {};
    uint16_t lineCount = 1;
    const int32_t spaceWidth = M5.Display.textWidth(" ");
    const String content(text);
    const auto performLayout = [&](bool render, int32_t verticalOffset) {
        int32_t cursorX = 0;
        int32_t cursorY = verticalOffset;
        uint16_t lineIndex = 0;
        const auto alignedX = [&]() {
            if (horizontalAlignment == 1) {
                return (width - lineWidths[lineIndex]) / 2;
            }
            return horizontalAlignment == 2 ? width - lineWidths[lineIndex] : 0;
        };
        const auto nextLine = [&]() {
            if (!render) {
                lineWidths[lineIndex] = cursorX;
            }
            cursorX = 0;
            cursorY += lineHeight;
            ++lineIndex;
            return cursorY - verticalOffset + lineHeight <= height;
        };
        const auto renderWord = [&](const String& word) {
            if (word.isEmpty()) {
                return true;
            }
            const int32_t wordWidth = M5.Display.textWidth(word);
            if (wordWidth <= width) {
                if (cursorX > 0 && cursorX + wordWidth > width && !nextLine()) {
                    return false;
                }
                if (render) {
                    M5.Display.drawString(word, x + alignedX() + cursorX, y + cursorY);
                }
                cursorX += wordWidth;
                return true;
            }
            for (size_t index = 0; index < word.length(); ++index) {
                const String character(word[index]);
                const int32_t characterWidth = M5.Display.textWidth(character);
                if (cursorX > 0 && cursorX + characterWidth > width && !nextLine()) {
                    return false;
                }
                if (render) {
                    M5.Display.drawString(character, x + alignedX() + cursorX, y + cursorY);
                }
                cursorX += characterWidth;
            }
            return true;
        };

        String word;
        for (size_t index = 0; index <= content.length(); ++index) {
            const char character = index < content.length() ? content[index] : '\0';
            if (character != ' ' && character != '\n' && character != '\0') {
                word += character;
                continue;
            }
            if (!renderWord(word)) {
                return false;
            }
            word = "";
            if (character == '\n' && index + 1 < content.length()) {
                if (!nextLine()) {
                    return false;
                }
            } else if (character == ' ' && cursorX > 0) {
                if (cursorX + spaceWidth > width) {
                    if (!nextLine()) {
                        return false;
                    }
                } else {
                    cursorX += spaceWidth;
                }
            }
        }
        if (!render) {
            lineWidths[lineIndex] = cursorX;
            lineCount = lineIndex + 1;
        }
        return true;
    };

    if (!performLayout(false, 0)) {
        return false;
    }
    if (!draw) {
        return true;
    }
    const int32_t textHeight = lineCount * lineHeight;
    const int32_t verticalOffset = verticalAlignment == 1
        ? (height - textHeight) / 2
        : verticalAlignment == 2 ? height - textHeight : 0;
    return performLayout(true, verticalOffset);
}

void drawRemoteControl(const RemotePage& page, size_t index, bool pressed = false) {
    if (index >= page.controlCount) {
        return;
    }
    const RemoteControl& control = page.controls[index];
    RemoteControlFrame frame;
    if (!remoteControlFrame(page, index, frame)) {
        return;
    }
    const int32_t x = frame.x;
    const int32_t y = frame.y;
    const int32_t width = frame.width;
    const int32_t height = frame.height;

    if (control.kind == 2) {
        constexpr int32_t radius = 10;
        M5.Display.fillRoundRect(x, y, width, height, radius, TFT_WHITE);
        M5.Display.drawRoundRect(x, y, width, height, radius, TFT_BLACK);
        M5.Display.setClipRect(x + 8, y + 8, width - 16, height - 16);
        const lgfx::IFont* fonts[] = {
            &fonts::FreeSansBold9pt7b,
            &fonts::FreeSansBold12pt7b,
            &fonts::FreeSansBold18pt7b,
            &fonts::FreeSansBold24pt7b,
        };
        uint8_t fontIndex = min<uint8_t>(control.textSize, 3);
        if (control.textSize == 4) {
            fontIndex = 0;
            for (int8_t candidate = 3; candidate >= 0; --candidate) {
                M5.Display.setFont(fonts[candidate]);
                if (layoutRemoteText(
                    control.resolvedText, 0, 0, width - 16, height - 16,
                    control.textHorizontalAlignment, control.textVerticalAlignment, false)) {
                    fontIndex = candidate;
                    break;
                }
            }
        }
        M5.Display.setFont(fonts[fontIndex]);
        M5.Display.setTextColor(TFT_BLACK, TFT_WHITE);
        M5.Display.setTextDatum(textdatum_t::top_left);
        layoutRemoteText(
            control.resolvedText, x + 8, y + 8, width - 16, height - 16,
            control.textHorizontalAlignment, control.textVerticalAlignment, true);
        M5.Display.clearClipRect();
        return;
    }

    if (control.slider) {
        constexpr int32_t radius = 10;
        const int32_t inset = 3;
        const int32_t innerWidth = width - inset * 2;
        const int32_t fillWidth = constrain(control.action.value, 0, 255) * innerWidth / 255;
        M5.Display.fillRect(x, y, width, height, TFT_WHITE);
        M5.Display.drawRoundRect(x, y, width, height, radius, TFT_BLACK);
        if (fillWidth > 0) {
            M5.Display.fillRoundRect(
                x + inset,
                y + inset,
                fillWidth,
                height - inset * 2,
                min(radius - inset, fillWidth / 2),
                TFT_BLACK);
        }
        const auto drawSliderContent = [&](uint32_t foreground, uint32_t background) {
            M5.Display.setTextColor(foreground);
            M5.Display.setFont(&fonts::FreeSansBold12pt7b);
            drawRemoteControlIcon(control.symbol,
                control.hasIconBitmap ? control.iconBitmap : nullptr,
                control.iconDimension,
                x + 28, y + height / 2, control.hasIconBitmap ? 32 : 18,
                foreground, background);
            M5.Display.setTextDatum(textdatum_t::middle_left);
            M5.Display.drawString(control.title, x + 50, y + height / 2);
        };
        drawSliderContent(TFT_BLACK, TFT_WHITE);
        if (fillWidth > 0) {
            M5.Display.setClipRect(x + inset, y + inset, fillWidth, height - inset * 2);
            drawSliderContent(TFT_WHITE, TFT_BLACK);
            M5.Display.clearClipRect();
        }
        M5.Display.setTextColor(TFT_BLACK, TFT_WHITE);
        return;
    }

    const bool active = control.toggle ? control.toggleOn : pressed;
    const uint32_t foreground = active ? TFT_WHITE : TFT_BLACK;
    const uint32_t background = active ? TFT_BLACK : TFT_WHITE;
    constexpr int32_t radius = 10;
    M5.Display.fillRoundRect(x, y, width, height, radius, background);
    if (!active) {
        M5.Display.drawRoundRect(x, y, width, height, radius, foreground);
    }
    M5.Display.setTextColor(foreground, background);
    M5.Display.setFont(&fonts::FreeSansBold12pt7b);
    if (control.gridHeight == 1) {
        drawRemoteControlIcon(control.symbol,
            control.hasIconBitmap ? control.iconBitmap : nullptr,
            control.iconDimension,
            x + 28, y + height / 2, control.hasIconBitmap ? 32 : 18,
            foreground, background);
        M5.Display.setTextDatum(textdatum_t::middle_left);
        M5.Display.drawString(control.title, x + 50, y + height / 2);
    } else {
        M5.Display.setTextDatum(textdatum_t::middle_center);
        drawRemoteControlIcon(control.symbol,
            control.hasIconBitmap ? control.iconBitmap : nullptr,
            control.iconDimension,
            x + width / 2, y + 52, control.hasIconBitmap ? 64 : 28,
            foreground, background);
        M5.Display.drawCenterString(control.title, x + width / 2, y + 116);
    }
    M5.Display.setTextColor(TFT_BLACK, TFT_WHITE);
}

void clearRemoteControl(const RemotePage& page, size_t index) {
    RemoteControlFrame frame;
    if (remoteControlFrame(page, index, frame)) {
        M5.Display.fillRect(frame.x, frame.y, frame.width, frame.height, TFT_WHITE);
    }
}

void displayRemoteProfileChanges(
    const RemoteProfile& previousProfile,
    uint8_t previousPageIndex) {
    const RemotePage& previousPage = previousProfile.pages[previousPageIndex];
    const RemotePage& page = remoteProfile->pages[remotePageIndex];
    const bool pageNameChanged = strcmp(previousPage.name, page.name) != 0;
    const bool footerChanged = previousPageIndex != remotePageIndex ||
        previousProfile.pageCount != remoteProfile->pageCount;
    bool previousChanged[kMaximumRemoteControls] = {};
    bool changed[kMaximumRemoteControls] = {};
    bool previousMatched[kMaximumRemoteControls] = {};
    bool matched[kMaximumRemoteControls] = {};
    bool hasChangedControl = false;
    bool sliderValuesOnly = !pageNameChanged && !footerChanged;

    for (uint8_t index = 0; index < previousPage.controlCount; ++index) {
        previousChanged[index] = true;
    }
    for (uint8_t index = 0; index < page.controlCount; ++index) {
        changed[index] = true;
    }

    for (uint8_t previousIndex = 0; previousIndex < previousPage.controlCount; ++previousIndex) {
        const RemoteControl& previousControl = previousPage.controls[previousIndex];
        for (uint8_t index = 0; index < page.controlCount; ++index) {
            const RemoteControl& control = page.controls[index];
            const bool sameIdentity = previousControl.id[0] != '\0'
                ? strcmp(previousControl.id, control.id) == 0
                : previousIndex == index && control.id[0] == '\0';
            if (!sameIdentity) {
                continue;
            }
            previousMatched[previousIndex] = true;
            matched[index] = true;
            RemoteControlFrame previousFrame;
            RemoteControlFrame frame;
            const bool sameFrame = remoteControlFrame(previousPage, previousIndex, previousFrame) &&
                remoteControlFrame(page, index, frame) &&
                previousFrame.x == frame.x && previousFrame.y == frame.y &&
                previousFrame.width == frame.width && previousFrame.height == frame.height;
            const bool sameTitle = strcmp(previousControl.title, control.title) == 0;
            const bool sameSymbol = strcmp(previousControl.symbol, control.symbol) == 0;
            const bool sameIcon = previousControl.hasIconBitmap == control.hasIconBitmap &&
                previousControl.iconDimension == control.iconDimension &&
                (!control.hasIconBitmap ||
                    memcmp(previousControl.iconBitmap, control.iconBitmap, sizeof(control.iconBitmap)) == 0);
            const bool sameToggle = previousControl.toggle == control.toggle &&
                previousControl.toggleOn == control.toggleOn;
            const bool sameTextBox = previousControl.kind != 2 ||
                (control.kind == 2 && previousControl.textSize == control.textSize &&
                 previousControl.textHorizontalAlignment == control.textHorizontalAlignment &&
                 previousControl.textVerticalAlignment == control.textVerticalAlignment &&
                 strcmp(previousControl.resolvedText, control.resolvedText) == 0);
            const bool sameAppearance = sameFrame && sameTitle && sameSymbol && sameIcon && sameToggle &&
                previousControl.kind == control.kind && sameTextBox &&
                previousControl.slider == control.slider &&
                (!control.slider || previousControl.action.value == control.action.value);
            if (sameAppearance) {
                previousChanged[previousIndex] = false;
                changed[index] = false;
            } else if (!(sameFrame && sameTitle && sameSymbol && sameIcon && sameToggle &&
                         previousControl.slider && control.slider &&
                         previousControl.action.value != control.action.value)) {
                sliderValuesOnly = false;
            }
            break;
        }
    }

    for (uint8_t index = 0; index < previousPage.controlCount; ++index) {
        hasChangedControl = hasChangedControl || previousChanged[index];
        sliderValuesOnly = sliderValuesOnly && previousMatched[index];
    }
    for (uint8_t index = 0; index < page.controlCount; ++index) {
        hasChangedControl = hasChangedControl || changed[index];
        sliderValuesOnly = sliderValuesOnly && matched[index];
    }

    if (!pageNameChanged && !footerChanged && !hasChangedControl) {
        return;
    }

    M5.Display.setEpdMode(
        sliderValuesOnly ? epd_mode_t::epd_fastest : epd_mode_t::epd_text);
    M5.Display.startWrite();
    if (pageNameChanged) {
        M5.Display.fillRect(20, 28, 400, 66, TFT_WHITE);
        M5.Display.setTextColor(TFT_BLACK, TFT_WHITE);
        M5.Display.setTextDatum(textdatum_t::top_left);
        M5.Display.setFont(&fonts::Orbitron_Light_24);
        M5.Display.drawString(page.name, 24, 38);
    }
    for (uint8_t index = 0; index < previousPage.controlCount; ++index) {
        if (previousChanged[index]) {
            clearRemoteControl(previousPage, index);
        }
    }
    for (uint8_t index = 0; index < page.controlCount; ++index) {
        if (changed[index]) {
            drawRemoteControl(page, index);
        }
    }
    if (footerChanged) {
        M5.Display.fillRect(160, 850, 220, 68, TFT_WHITE);
        M5.Display.setTextColor(TFT_BLACK, TFT_WHITE);
        M5.Display.setTextDatum(textdatum_t::middle_center);
        M5.Display.setFont(&fonts::FreeMonoBold12pt7b);
        char pageText[24];
        snprintf(pageText, sizeof(pageText), "<  %u / %u  >",
            remotePageIndex + 1, remoteProfile->pageCount);
        M5.Display.drawCenterString(pageText, kDisplayWidth / 2, 884);
    }
    M5.Display.endWrite();
}

void displayRemoteControlFeedback(size_t index, bool pressed) {
    const RemotePage& page = remoteProfile->pages[remotePageIndex];
    RemoteControlFrame frame;
    if (!remoteControlFrame(page, index, frame) || page.controls[index].slider) {
        return;
    }
    const int32_t x = frame.x;
    const int32_t y = frame.y;
    const int32_t width = frame.width;
    const int32_t height = frame.height;

    M5.Display.setEpdMode(epd_mode_t::epd_fast);
    M5.Display.startWrite();
    if (pressed) {
        constexpr int32_t radius = 10;
        for (int32_t inset = 3; inset <= 5; ++inset) {
            M5.Display.drawRoundRect(
                x + inset,
                y + inset,
                width - inset * 2,
                height - inset * 2,
                radius - inset,
                TFT_BLACK);
        }
    } else {
        drawRemoteControl(page, index);
    }
    M5.Display.endWrite();
    M5.Display.waitDisplay();
}

void displayRemoteSliderValue(
    const RemotePage& page,
    size_t index,
    bool waitForCompletion = false) {
    M5.Display.setEpdMode(epd_mode_t::epd_fastest);
    M5.Display.startWrite();
    drawRemoteControl(page, index);
    M5.Display.endWrite();
    if (waitForCompletion) {
        M5.Display.waitDisplay();
    }
}

void drawRemoteIconLine(int32_t x0, int32_t y0, int32_t x1, int32_t y1) {
    M5.Display.drawLine(x0, y0, x1, y1, TFT_BLACK);
    if (abs(x1 - x0) >= abs(y1 - y0)) {
        M5.Display.drawLine(x0, y0 - 1, x1, y1 - 1, TFT_BLACK);
        M5.Display.drawLine(x0, y0 + 1, x1, y1 + 1, TFT_BLACK);
    } else {
        M5.Display.drawLine(x0 - 1, y0, x1 - 1, y1, TFT_BLACK);
        M5.Display.drawLine(x0 + 1, y0, x1 + 1, y1, TFT_BLACK);
    }
}

bool isHomeWifiAuthenticationFailure(uint16_t reason) {
    return reason == WIFI_REASON_AUTH_FAIL ||
        reason == WIFI_REASON_4WAY_HANDSHAKE_TIMEOUT ||
        reason == WIFI_REASON_HANDSHAKE_TIMEOUT;
}

void drawRemoteStatusLine() {
    M5.Display.fillRect(24, 110, 410, 28, TFT_WHITE);
    M5.Display.setTextColor(TFT_BLACK, TFT_WHITE);
    M5.Display.setTextDatum(textdatum_t::top_left);
    M5.Display.setFont(&fonts::FreeSansBold9pt7b);
    if (remoteActionStatus[0] != '\0') {
        M5.Display.drawString(remoteActionStatus, 24, 116);
    } else if (homeWifiState == 1) {
        M5.Display.drawString("Connecting to Wi-Fi...", 24, 116);
    } else if (homeWifiState == 3) {
        char errorText[64];
        if (isHomeWifiAuthenticationFailure(homeWifiFailureReason)) {
            strlcpy(errorText, "Wi-Fi authentication failed", sizeof(errorText));
        } else if (homeWifiFailureReason == WIFI_REASON_NO_AP_FOUND) {
            strlcpy(errorText, "Wi-Fi network was not found", sizeof(errorText));
        } else if (homeWifiFailureReason == 0) {
            strlcpy(errorText, "Wi-Fi connection timed out", sizeof(errorText));
        } else {
            snprintf(errorText, sizeof(errorText), "Wi-Fi failed (reason %u)", homeWifiFailureReason);
        }
        M5.Display.drawString(errorText, 24, 116);
    }
}

int8_t sampleRemoteBatteryLevel() {
    remoteBatterySampledAt = millis();
    const int32_t level = M5.Power.getBatteryLevel();
    return level < 0 ? -1 : static_cast<int8_t>(constrain(level, 0, 100));
}

void drawRemoteBatteryIndicator() {
    constexpr int32_t regionX = 436;
    constexpr int32_t regionY = 38;
    constexpr int32_t regionWidth = 80;
    constexpr int32_t regionHeight = 38;
    constexpr int32_t bodyX = 480;
    constexpr int32_t bodyY = 49;
    constexpr int32_t bodyWidth = 30;
    constexpr int32_t bodyHeight = 16;
    constexpr int32_t fillWidth = bodyWidth - 4;

    M5.Display.fillRect(regionX, regionY, regionWidth, regionHeight, TFT_WHITE);
    M5.Display.drawRect(bodyX, bodyY, bodyWidth, bodyHeight, TFT_BLACK);
    M5.Display.fillRect(bodyX + bodyWidth, bodyY + 5, 3, 6, TFT_BLACK);
    if (remoteBatteryLevel >= 0) {
        const int32_t levelWidth = remoteBatteryLevel * fillWidth / 100;
        if (levelWidth > 0) {
            M5.Display.fillRect(bodyX + 2, bodyY + 2, levelWidth, bodyHeight - 4, TFT_BLACK);
        }
    }

    char percentage[8];
    if (remoteBatteryLevel >= 0) {
        snprintf(percentage, sizeof(percentage), "%d%%", remoteBatteryLevel);
    } else {
        strlcpy(percentage, "--%", sizeof(percentage));
    }
    M5.Display.setTextColor(TFT_BLACK, TFT_WHITE);
    M5.Display.setFont(&fonts::FreeSansBold9pt7b);
    M5.Display.setTextDatum(textdatum_t::middle_right);
    M5.Display.drawString(percentage, bodyX - 8, bodyY + bodyHeight / 2);
}

void refreshRemoteBatteryIndicator() {
    const int8_t nextLevel = sampleRemoteBatteryLevel();
    if (nextLevel == remoteBatteryLevel) {
        return;
    }
    remoteBatteryLevel = nextLevel;
    M5.Display.setEpdMode(epd_mode_t::epd_fastest);
    M5.Display.startWrite();
    drawRemoteBatteryIndicator();
    M5.Display.endWrite();
}

void displayRemoteActionStatus(const char* message) {
    if (!remoteVisible) {
        return;
    }
    remoteActionStatusClearAt = millis() + 2000;
    if (strcmp(remoteActionStatus, message) == 0) {
        return;
    }
    strlcpy(remoteActionStatus, message, sizeof(remoteActionStatus));
    M5.Display.setEpdMode(epd_mode_t::epd_fastest);
    M5.Display.startWrite();
    drawRemoteStatusLine();
    M5.Display.endWrite();
}

void displayRemote() {
    if (remoteProfile == nullptr || !remoteProfile->configured) {
        return;
    }
    M5.Display.setEpdMode(epd_mode_t::epd_quality);
    activeRemoteControlIndex = -1;
    activeRemoteControlVisual = false;
    activeRemoteHoldTriggered = false;
    M5.Display.startWrite();
    M5.Display.fillScreen(TFT_WHITE);
    M5.Display.setTextColor(TFT_BLACK, TFT_WHITE);
    M5.Display.setTextDatum(textdatum_t::top_left);
    M5.Display.setFont(&fonts::Orbitron_Light_24);
    M5.Display.drawString(remoteProfile->pages[remotePageIndex].name, 24, 38);
    M5.Display.setFont(&fonts::FreeSansBold9pt7b);
    constexpr int32_t wifiIconX = 414;
    constexpr int32_t wifiIconY = 57;
    M5.Display.fillCircle(wifiIconX, wifiIconY, 3, TFT_BLACK);
    drawRemoteIconLine(wifiIconX - 5, wifiIconY - 5, wifiIconX, wifiIconY - 9);
    drawRemoteIconLine(wifiIconX, wifiIconY - 9, wifiIconX + 5, wifiIconY - 5);
    drawRemoteIconLine(wifiIconX - 10, wifiIconY - 10, wifiIconX, wifiIconY - 17);
    drawRemoteIconLine(wifiIconX, wifiIconY - 17, wifiIconX + 10, wifiIconY - 10);
    if (homeWifiState == 0 || homeWifiState == 3) {
        drawRemoteIconLine(wifiIconX - 10, wifiIconY - 18, wifiIconX + 10, wifiIconY + 2);
    }
    remoteBatteryLevel = sampleRemoteBatteryLevel();
    drawRemoteBatteryIndicator();
    M5.Display.drawFastHLine(24, 106, 492, TFT_BLACK);
    remoteActionStatus[0] = '\0';
    remoteActionStatusClearAt = 0;
    drawRemoteStatusLine();

    prepareRemoteTextBoxes();
    const RemotePage& page = remoteProfile->pages[remotePageIndex];
    for (size_t index = 0; index < page.controlCount; ++index) {
        drawRemoteControl(page, index);
    }
    M5.Display.setTextDatum(textdatum_t::middle_center);
    M5.Display.setFont(&fonts::FreeMonoBold12pt7b);
    char pageText[24];
    snprintf(pageText, sizeof(pageText), "<  %u / %u  >",
        remotePageIndex + 1, remoteProfile->pageCount);
    M5.Display.drawCenterString(pageText, kDisplayWidth / 2, 884);
    M5.Display.endWrite();
    M5.Display.waitDisplay();
    remoteVisible = true;
    screensaverActive = false;
    settingsVisible = false;
    libraryVisible = false;
    slideshowMenuVisible = false;
    wifiModeVisible = false;
}

void connectHomeWifi() {
    if (remoteProfile == nullptr || !remoteProfile->configured) {
        return;
    }
    if (remoteProfile->wifiSsid[0] == '\0') {
        homeWifiState = 0;
        homeWifiAuthenticationFailures = 0;
        homeWifiAuthenticationRetryPending = false;
        homeWifiFailureReason = 0;
        homeWifiStatusChanged = true;
        homeWifiNotificationPending = true;
        Serial.println("Home Wi-Fi is not configured");
        return;
    }
    WiFi.mode(wifiActive ? WIFI_AP_STA : WIFI_STA);
    WiFi.setSleep(true);
    homeWifiState = 1;
    homeWifiAuthenticationRetryPending = false;
    homeWifiFailureReason = 0;
    homeWifiStatusChanged = true;
    homeWifiNotificationPending = true;
    WiFi.begin(remoteProfile->wifiSsid, remoteProfile->wifiPassword);
    homeWifiConnecting = true;
    homeWifiAttemptedAt = millis();
    Serial.printf("Connecting to home Wi-Fi: %s\n", remoteProfile->wifiSsid);
}

bool postJson(const String& url, const String& body, const char* token = nullptr) {
    String ignored;
    return postJsonResponse(url, body, ignored, token);
}

bool postJsonResponse(
    const String& url,
    const String& body,
    String& responseBody,
    const char* token = nullptr) {
    if (WiFi.status() != WL_CONNECTED || !url.startsWith("http://")) {
        return false;
    }
    String address = url.substring(7);
    const int pathStart = address.indexOf('/');
    String authority = pathStart >= 0 ? address.substring(0, pathStart) : address;
    const String path = pathStart >= 0 ? address.substring(pathStart) : "/";
    uint16_t port = 80;
    const int portSeparator = authority.lastIndexOf(':');
    if (portSeparator >= 0) {
        port = static_cast<uint16_t>(authority.substring(portSeparator + 1).toInt());
        authority.remove(portSeparator);
    }

    WiFiClient client;
    client.setTimeout(3000);
    if (!client.connect(authority.c_str(), port)) {
        return false;
    }
    client.printf("POST %s HTTP/1.1\r\n", path.c_str());
    client.printf("Host: %s\r\n", authority.c_str());
    client.print("Content-Type: application/json\r\nConnection: close\r\n");
    if (token != nullptr && token[0] != '\0') {
        client.printf("Authorization: Bearer %s\r\n", token);
    }
    client.printf("Content-Length: %u\r\n\r\n", body.length());
    client.print(body);
    const String statusLine = client.readStringUntil('\n');
    const int firstSpace = statusLine.indexOf(' ');
    const int status = firstSpace >= 0 ? statusLine.substring(firstSpace + 1).toInt() : 0;
    int contentLength = -1;
    while (client.connected() || client.available()) {
        const String line = client.readStringUntil('\n');
        if (line == "\r" || line.length() == 0) {
            break;
        }
        if (line.startsWith("Content-Length:")) {
            contentLength = line.substring(15).toInt();
        }
    }
    if (contentLength > 4096) {
        client.stop();
        return false;
    }
    responseBody = "";
    if (contentLength >= 0) {
        responseBody.reserve(contentLength);
        char buffer[256];
        int remaining = contentLength;
        while (remaining > 0) {
            const size_t received = client.readBytes(
                buffer,
                min<int>(remaining, sizeof(buffer)));
            if (received == 0) {
                client.stop();
                return false;
            }
            responseBody.concat(buffer, received);
            remaining -= received;
        }
    } else {
        responseBody = client.readString();
    }
    client.stop();
    return status >= 200 && status < 300;
}

RemoteComputer* textBoxComputer(RemoteControl& control) {
    const char* identifier = control.textComputerId[0] != '\0'
        ? control.textComputerId : control.action.computerId;
    if (identifier[0] != '\0') {
        for (uint8_t index = 0; index < remoteProfile->computerCount; ++index) {
            if (strcmp(remoteProfile->computers[index].id, identifier) == 0) {
                return &remoteProfile->computers[index];
            }
        }
    }
    return remoteProfile->computerCount > 0 ? &remoteProfile->computers[0] : nullptr;
}

void appendPaddedNumber(String& output, uint16_t value, uint8_t width, char padding = '0') {
    const String digits(value);
    for (uint8_t index = digits.length(); index < width; ++index) {
        output += padding;
    }
    output += digits;
}

String formatRtcDateTime(const m5::rtc_datetime_t& dateTime, const char* format) {
    static constexpr const char* kShortMonths[] = {
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    };
    static constexpr const char* kLongMonths[] = {
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    };
    static constexpr const char* kShortWeekdays[] = {
        "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat",
    };
    static constexpr const char* kLongWeekdays[] = {
        "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
    };
    const uint8_t monthIndex = dateTime.date.month >= 1 && dateTime.date.month <= 12
        ? dateTime.date.month - 1 : 0;
    const uint8_t weekdayIndex = dateTime.date.weekDay <= 6 ? dateTime.date.weekDay : 0;
    const uint8_t twelveHour = dateTime.time.hours % 12 == 0 ? 12 : dateTime.time.hours % 12;
    String output;
    output.reserve(64);
    for (size_t index = 0; format[index] != '\0' && output.length() < 192; ++index) {
        if (format[index] != '%' || format[index + 1] == '\0') {
            output += format[index];
            continue;
        }
        const char token = format[++index];
        switch (token) {
            case '%': output += '%'; break;
            case 'Y': appendPaddedNumber(output, dateTime.date.year, 4); break;
            case 'y': appendPaddedNumber(output, dateTime.date.year % 100, 2); break;
            case 'm': appendPaddedNumber(output, dateTime.date.month, 2); break;
            case 'b': output += kShortMonths[monthIndex]; break;
            case 'B': output += kLongMonths[monthIndex]; break;
            case 'd': appendPaddedNumber(output, dateTime.date.date, 2); break;
            case 'e': appendPaddedNumber(output, dateTime.date.date, 2, ' '); break;
            case 'a': output += kShortWeekdays[weekdayIndex]; break;
            case 'A': output += kLongWeekdays[weekdayIndex]; break;
            case 'H': appendPaddedNumber(output, dateTime.time.hours, 2); break;
            case 'I': appendPaddedNumber(output, twelveHour, 2); break;
            case 'M': appendPaddedNumber(output, dateTime.time.minutes, 2); break;
            case 'S': appendPaddedNumber(output, dateTime.time.seconds, 2); break;
            case 'p': output += dateTime.time.hours < 12 ? "AM" : "PM"; break;
            default:
                output += '%';
                output += token;
                break;
        }
    }
    return output.substring(0, 192);
}

bool resolveLocalTextBox(RemoteControl& control) {
    String text;
    if (strcmp(control.textSource, "staticText") == 0) {
        text = control.sourceText;
    } else if (strcmp(control.textSource, "dateTime") == 0) {
        m5::rtc_datetime_t dateTime;
        const bool validTime = M5.Rtc.getDateTime(&dateTime) && dateTime.date.year >= 2020;
        if (validTime) {
            text = formatRtcDateTime(dateTime, control.dateFormat);
        } else {
            text = control.placeholder;
        }
    } else if (strcmp(control.textSource, "controlValue") == 0) {
        for (uint8_t pageIndex = 0; pageIndex < remoteProfile->pageCount; ++pageIndex) {
            RemotePage& page = remoteProfile->pages[pageIndex];
            for (uint8_t index = 0; index < page.controlCount; ++index) {
                RemoteControl& referenced = page.controls[index];
                if (strcmp(referenced.id, control.referencedControlId) != 0) {
                    continue;
                }
                text = referenced.slider
                    ? String(referenced.action.value)
                    : (referenced.toggleOn ? "On" : "Off");
                break;
            }
        }
        if (text.isEmpty()) {
            text = control.placeholder;
        }
    } else {
        return false;
    }
    if (text == control.resolvedText) {
        return false;
    }
    strlcpy(control.resolvedText, text.c_str(), sizeof(control.resolvedText));
    return true;
}

void redrawRemoteTextBox(RemotePage& page, uint8_t index) {
    if (!remoteVisible || &page != &remoteProfile->pages[remotePageIndex]) {
        return;
    }
    M5.Display.setEpdMode(epd_mode_t::epd_fastest);
    M5.Display.startWrite();
    drawRemoteControl(page, index);
    M5.Display.endWrite();
}

void refreshReferencedTextBoxes(RemotePage& page, const char* controlId) {
    if (!remoteVisible || &page != &remoteProfile->pages[remotePageIndex]) {
        return;
    }
    for (uint8_t index = 0; index < page.controlCount; ++index) {
        RemoteControl& textBox = page.controls[index];
        if (textBox.kind == 2 && strcmp(textBox.textSource, "controlValue") == 0 &&
            strcmp(textBox.referencedControlId, controlId) == 0 && resolveLocalTextBox(textBox)) {
            redrawRemoteTextBox(page, index);
        }
    }
}

bool isMacTextSource(const RemoteControl& control) {
    return strncmp(control.textSource, "mac", 3) == 0 ||
        strcmp(control.textSource, "nowPlaying") == 0;
}

uint32_t textBoxRefreshIntervalMs(const RemoteControl& control) {
    return strcmp(control.textSource, "nowPlaying") == 0
    ? 60000 : control.refreshIntervalMs;
}

void fetchMacTextBoxes(RemotePage& page, RemoteComputer& computer, uint32_t now) {
    JsonDocument request;
    JsonArray items = request["items"].to<JsonArray>();
    for (uint8_t index = 0; index < page.controlCount; ++index) {
        RemoteControl& control = page.controls[index];
        if (control.kind != 2 || !isMacTextSource(control) ||
            control.nextRefreshAt == 0 || static_cast<int32_t>(now - control.nextRefreshAt) < 0 ||
            textBoxComputer(control) != &computer) {
            continue;
        }
        JsonObject item = items.add<JsonObject>();
        item["id"] = control.id;
        item["source"] = control.textSource;
        item["sourceText"] = control.sourceText;
        item["placeholder"] = control.placeholder;
        const uint32_t refreshIntervalMs = textBoxRefreshIntervalMs(control);
        control.nextRefreshAt = now + (refreshIntervalMs > 0 ? refreshIntervalMs : 5000);
    }
    if (items.size() == 0 || WiFi.status() != WL_CONNECTED) {
        if (items.size() > 0) {
            Serial.println("Text refresh deferred: Wi-Fi disconnected");
        }
        return;
    }
    Serial.printf("Refreshing %u text box(es) from %s:%u\n",
        static_cast<unsigned>(items.size()), computer.host, computer.port);
    String body;
    serializeJson(request, body);
    String response;
    const String url = "http://" + String(computer.host) + ":" + computer.port + "/text-source";
    if (!postJsonResponse(url, body, response, computer.token)) {
        Serial.println("Text refresh failed: companion request rejected or timed out");
        return;
    }
    JsonDocument document;
    if (deserializeJson(document, response)) {
        Serial.println("Text refresh failed: invalid companion response");
        return;
    }
    for (JsonObject result : document["items"].as<JsonArray>()) {
        const char* identifier = result["id"] | "";
        for (uint8_t index = 0; index < page.controlCount; ++index) {
            RemoteControl& control = page.controls[index];
            if (strcmp(control.id, identifier) != 0) {
                continue;
            }
            const bool available = result["available"] | false;
            const uint32_t refreshIntervalMs = textBoxRefreshIntervalMs(control);
            control.nextRefreshAt = refreshIntervalMs > 0
                ? now + refreshIntervalMs : 0;
            if (!available && control.hasResolvedValue) {
                break;
            }
            const char* text = result["text"] | control.placeholder;
            const bool changed = strcmp(text, control.resolvedText) != 0;
            strlcpy(control.resolvedText, text, sizeof(control.resolvedText));
            control.hasResolvedValue = control.hasResolvedValue || available;
            Serial.printf("Text source %s: %s%s\n", control.id,
                available ? "available" : "unavailable",
                changed ? ", changed" : ", unchanged");
            if (changed) {
                redrawRemoteTextBox(page, index);
            }
            break;
        }
    }
}

void prepareRemoteTextBoxes() {
    if (remoteProfile == nullptr || remotePageIndex >= remoteProfile->pageCount) {
        return;
    }
    RemotePage& page = remoteProfile->pages[remotePageIndex];
    for (uint8_t index = 0; index < page.controlCount; ++index) {
        RemoteControl& control = page.controls[index];
        if (control.kind != 2) {
            continue;
        }
        resolveLocalTextBox(control);
        const bool macSource = isMacTextSource(control);
        control.nextRefreshAt = macSource ? millis() :
            (control.refreshIntervalMs > 0 ? millis() + control.refreshIntervalMs : 0);
    }
}

void pollRemoteTextBoxes() {
    if (!remoteVisible || remoteProfile == nullptr || remotePageIndex >= remoteProfile->pageCount) {
        return;
    }
    RemotePage& page = remoteProfile->pages[remotePageIndex];
    const uint32_t now = millis();
    RemoteComputer* dueComputer = nullptr;
    for (uint8_t index = 0; index < page.controlCount; ++index) {
        RemoteControl& control = page.controls[index];
        if (control.kind != 2 || control.nextRefreshAt == 0 ||
            static_cast<int32_t>(now - control.nextRefreshAt) < 0) {
            continue;
        }
        if (isMacTextSource(control)) {
            dueComputer = textBoxComputer(control);
            if (dueComputer != nullptr) {
                break;
            }
        } else {
            const bool changed = resolveLocalTextBox(control);
            control.nextRefreshAt = control.refreshIntervalMs > 0
                ? now + control.refreshIntervalMs : 0;
            if (changed) {
                redrawRemoteTextBox(page, index);
            }
            return;
        }
    }
    if (dueComputer != nullptr) {
        fetchMacTextBoxes(page, *dueComputer, now);
    }
}

bool dispatchRemoteAction(RemoteControl& control) {
    RemoteAction& action = control.action;
    if (strcmp(action.type, "page") == 0) {
        for (uint8_t index = 0; index < remoteProfile->pageCount; ++index) {
            if (strcmp(remoteProfile->pages[index].id, action.text) == 0) {
                remotePageIndex = index;
                displayRemote();
                return true;
            }
        }
        Serial.printf("Remote action %s failed: page not found\n", action.type);
        return false;
    }

    JsonDocument document;
    String url;
    const char* token = nullptr;
    if (strncmp(action.type, "wled", 4) == 0) {
        if (action.host[0] == '\0') {
            Serial.printf("Remote action %s failed: WLED host is empty\n", action.type);
            return false;
        }
        String host = action.host;
        if (!host.startsWith("http://") && !host.startsWith("https://")) {
            host = "http://" + host;
        }
        while (host.endsWith("/")) {
            host.remove(host.length() - 1);
        }
        url = host + "/json/state";
        if (strcmp(action.type, "wledPower") == 0) {
            if (control.toggle) {
                document["on"] = !control.toggleOn;
            } else if (strcmp(action.text, "on") == 0) {
                document["on"] = true;
            } else if (strcmp(action.text, "off") == 0) {
                document["on"] = false;
            } else {
                document["on"] = "t";
            }
        } else if (strcmp(action.type, "wledPreset") == 0) {
            document["ps"] = constrain(action.value, 1, 250);
        } else if (strcmp(action.type, "wledBrightness") == 0) {
            document["bri"] = constrain(action.value, 0, 255);
        } else {
            Serial.printf("Remote action %s failed: unsupported WLED action\n", action.type);
            return false;
        }
    } else {
        const char* macHost = remoteProfile->macHost;
        uint16_t macPort = remoteProfile->macPort;
        const char* macToken = remoteProfile->macToken;
        if (action.computerId[0] != '\0') {
            RemoteComputer* target = nullptr;
            for (uint8_t index = 0; index < remoteProfile->computerCount; ++index) {
                if (strcmp(remoteProfile->computers[index].id, action.computerId) == 0) {
                    target = &remoteProfile->computers[index];
                    break;
                }
            }
            if (target == nullptr) {
                Serial.printf("Remote action %s failed: computer %s not found\n",
                    action.type, action.computerId);
                return false;
            }
            macHost = target->host;
            macPort = target->port;
            macToken = target->token;
        }
        if (macHost[0] == '\0' || macToken[0] == '\0') {
            Serial.printf("Remote action %s failed: computer host or token is empty\n", action.type);
            return false;
        }
        url = "http://" + String(macHost) + ":" + macPort + "/action";
        token = macToken;
        document["type"] = action.type;
        document["text"] = action.text;
        document["value"] = action.value;
        JsonArray modifiers = document["modifiers"].to<JsonArray>();
        for (uint8_t index = 0; index < action.modifierCount; ++index) {
            modifiers.add(action.modifiers[index]);
        }
    }
    String body;
    serializeJson(document, body);
    if (WiFi.status() != WL_CONNECTED) {
        Serial.printf("Remote action %s failed: home Wi-Fi is disconnected\n", action.type);
        if (!control.slider) {
            displayRemoteActionStatus("Wi-Fi offline");
        }
        return false;
    }
    const bool sent = postJson(url, body, token);
    Serial.printf("Remote action %s -> %s\n", action.type, sent ? "ok" : "failed");
    if (!control.slider) {
        displayRemoteActionStatus(sent
            ? "Sent"
            : (strncmp(action.type, "wled", 4) == 0 ? "WLED unavailable" : "Computer unavailable"));
    }
    return sent;
}

void navigateRemote(int direction) {
    if (remoteProfile == nullptr || !remoteProfile->configured) {
        return;
    }
    if (direction < 0) {
        remotePageIndex = remotePageIndex == 0
            ? remoteProfile->pageCount - 1
            : remotePageIndex - 1;
    } else {
        remotePageIndex = (remotePageIndex + 1) % remoteProfile->pageCount;
    }
    lastRemoteActivityAt = millis();
    displayRemote();
}

void selectLibraryItem(size_t index) {
    if (index >= libraryItemCount) {
        return;
    }
    char path[kMaximumPathBytes];
    strlcpy(path, libraryItems[index].path, sizeof(path));
    libraryVisible = false;
    recoveredFromRenderCrash = false;
    if (loadAnimation(path)) {
        persistActiveSelection();
        displayCurrentFrame();
    } else {
        libraryVisible = true;
        displayLibrary();
    }
}

size_t activeLibraryIndex() {
    for (size_t index = 0; index < libraryItemCount; ++index) {
        if (strcmp(libraryItems[index].path, activeAnimationPath) == 0) {
            return index;
        }
    }
    return 0;
}

void prepareNextSlideshowItem() {
    if (libraryItemCount == 0) {
        return;
    }
    const size_t nextIndex = (activeLibraryIndex() + 1) % libraryItemCount;
    if (loadAnimation(libraryItems[nextIndex].path)) {
        persistActiveSelection();
    }
}

void showLibrary() {
    refreshLibrary();
    librarySelection = activeLibraryIndex();
    libraryPage = librarySelection / kLibraryRowsPerPage;
    displayLibrary();
}

void closeSlideshowMenu() {
    slideshowMenuVisible = false;
    if (remoteProfile != nullptr && remoteProfile->configured) {
        displaySettings();
    } else {
        deepSleepSuspended = false;
        if (animationReady) {
            stillFrameDisplayed = false;
            displayedFrames = 0;
            nextFrameAt = millis();
            nextSlideshowAt = millis() + slideshowIntervalMs();
        } else {
            splashPending = true;
        }
    }
}

void navigateLibrary(int direction) {
    if (libraryItemCount == 0) {
        return;
    }
    const size_t previousSelection = librarySelection;
    const size_t previousPage = libraryPage;
    if (direction < 0) {
        librarySelection = librarySelection == 0 ? libraryItemCount - 1 : librarySelection - 1;
    } else {
        librarySelection = (librarySelection + 1) % libraryItemCount;
    }
    libraryPage = librarySelection / kLibraryRowsPerPage;
    if (libraryPage != previousPage) {
        displayLibrary();
        return;
    }

    M5.Display.setEpdMode(epd_mode_t::epd_fastest);
    M5.Display.startWrite();
    drawLibraryRow(previousSelection, true);
    drawLibraryRow(librarySelection, true);
    M5.Display.endWrite();
}

void navigatePlayback(int direction) {
    refreshLibrary();
    if (libraryItemCount == 0) {
        return;
    }
    librarySelection = activeLibraryIndex();
    if (direction < 0) {
        librarySelection = librarySelection == 0 ? libraryItemCount - 1 : librarySelection - 1;
    } else {
        librarySelection = (librarySelection + 1) % libraryItemCount;
    }
    selectLibraryItem(librarySelection);
}

void handleSideButtons() {
    if (upload.active || remoteProfileUpload.active) {
        return;
    }
    const uint32_t now = millis();
    const bool previousPressed = previousButton.update(now);
    const bool menuPressed = menuButton.update(now);
    const bool nextPressed = nextButton.update(now);

    if (remoteVisible) {
        if (previousPressed) {
            navigateRemote(-1);
        } else if (nextPressed) {
            navigateRemote(1);
        } else if (menuPressed) {
            lastRemoteActivityAt = now;
        }
    } else if (settingsVisible) {
        if (menuPressed) {
            lastRemoteActivityAt = now;
            displayRemote();
        }
    } else if (screensaverActive && (previousPressed || menuPressed || nextPressed)) {
        lastRemoteActivityAt = now;
        displayRemote();
    } else if (wifiModeVisible) {
        if (menuPressed) {
            closeWifiMode();
        }
    } else if (slideshowMenuVisible) {
        if (previousPressed) {
            adjustSlideshowInterval(-1);
        } else if (nextPressed) {
            adjustSlideshowInterval(1);
        } else if (menuPressed) {
            closeSlideshowMenu();
        }
    } else if (libraryVisible) {
        if (previousPressed) {
            navigateLibrary(-1);
        } else if (nextPressed) {
            navigateLibrary(1);
        } else if (menuPressed) {
            if (libraryItemCount > 0) {
                selectLibraryItem(librarySelection);
            } else {
                libraryVisible = false;
                splashPending = true;
            }
        }
    } else if (menuPressed) {
        lastRemoteActivityAt = now;
        displayRemote();
    } else if (previousPressed) {
        navigatePlayback(-1);
    } else if (nextPressed) {
        navigatePlayback(1);
    }
}

void handleTouch() {
    const bool touchInterrupted = touchInterruptPending;
    touchInterruptPending = false;
    if (upload.active || remoteProfileUpload.active) {
        return;
    }

    if (screensaverActive && touchInterrupted &&
        remoteProfile != nullptr && remoteProfile->configured) {
        lastRemoteActivityAt = millis();
        displayRemote();
        return;
    }

    if (M5.Touch.getCount() == 0) {
        return;
    }
    const auto touch = M5.Touch.getDetail();

    if (screensaverActive && remoteProfile != nullptr && remoteProfile->configured) {
        if (touch.wasPressed() || touch.wasClicked()) {
            lastRemoteActivityAt = millis();
            displayRemote();
        }
        return;
    }

    if (remoteVisible) {
        lastRemoteActivityAt = millis();
        RemotePage& page = remoteProfile->pages[remotePageIndex];
        int32_t hitControl = -1;
        RemoteControlFrame hitFrame;
        for (size_t index = 0; index < page.controlCount; ++index) {
            RemoteControlFrame frame;
            if (remoteControlFrame(page, index, frame) &&
                touch.x >= frame.x && touch.x < frame.x + frame.width &&
                touch.y >= frame.y && touch.y < frame.y + frame.height) {
                hitControl = static_cast<int32_t>(index);
                hitFrame = frame;
                break;
            }
        }

        if (touch.wasPressed()) {
            if (hitControl >= 0) {
                activeRemoteControlIndex = static_cast<int8_t>(hitControl);
                activeRemoteTouchPage = remotePageIndex;
                activeRemoteControlVisual = true;
                activeRemoteHoldTriggered = false;
                activeRemoteTouchStartedAt = millis();
                activeRemoteLastRepeatAt = activeRemoteTouchStartedAt;
                activeRemoteSliderRenderedAt = 0;
                activeRemoteSliderSentAt = 0;
                activeRemoteSliderSentValue = -1;
                Serial.printf("Remote control pressed: page=%u index=%d\n",
                    remotePageIndex, hitControl);
                RemoteControl& control = page.controls[hitControl];
                if (control.slider) {
                    control.action.value = constrain(
                        (touch.x - hitFrame.x) * 255 / hitFrame.width, 0, 255);
                    displayRemoteSliderValue(page, hitControl);
                    activeRemoteSliderRenderedAt = millis();
                    dispatchRemoteAction(control);
                    activeRemoteSliderSentAt = millis();
                    activeRemoteSliderSentValue = control.action.value;
                } else if (control.kind == 0) {
                    displayRemoteControlFeedback(hitControl, true);
                }
            }
            return;
        }

        if (activeRemoteControlIndex >= 0 && activeRemoteTouchPage == remotePageIndex) {
            const bool insideCapturedControl = hitControl == activeRemoteControlIndex;
            RemoteControl& control = page.controls[activeRemoteControlIndex];
            if (!control.slider && touch.isPressed() &&
                insideCapturedControl != activeRemoteControlVisual) {
                activeRemoteControlVisual = insideCapturedControl;
                displayRemoteControlFeedback(activeRemoteControlIndex, insideCapturedControl);
            }

            if (touch.isPressed() && control.slider) {
                RemoteControlFrame sliderFrame;
                if (remoteControlFrame(page, activeRemoteControlIndex, sliderFrame)) {
                    const int nextValue = constrain(
                        (touch.x - sliderFrame.x) * 255 / sliderFrame.width, 0, 255);
                    if (nextValue != control.action.value) {
                        control.action.value = nextValue;
                        const uint32_t now = millis();
                        if (now - activeRemoteSliderRenderedAt >= 120) {
                            displayRemoteSliderValue(page, activeRemoteControlIndex);
                            activeRemoteSliderRenderedAt = millis();
                        }
                        if (now - activeRemoteSliderSentAt >= 180) {
                            dispatchRemoteAction(control);
                            activeRemoteSliderSentAt = millis();
                            activeRemoteSliderSentValue = control.action.value;
                        }
                    }
                }
            }

            const uint32_t now = millis();
            const bool repeatsOnHold =
                (strcmp(control.action.type, "macKey") == 0) ||
                (strcmp(control.action.type, "macMedia") == 0 &&
                    (strcmp(control.action.text, "volumeUp") == 0 ||
                     strcmp(control.action.text, "volumeDown") == 0));
            if (control.kind == 0 && !control.toggle && touch.isPressed() && insideCapturedControl &&
                now - activeRemoteTouchStartedAt >= 500 &&
                (!activeRemoteHoldTriggered ||
                 (repeatsOnHold && now - activeRemoteLastRepeatAt >= 250))) {
                activeRemoteHoldTriggered = true;
                activeRemoteLastRepeatAt = now;
                Serial.printf("Remote control held: page=%u index=%d\n",
                    remotePageIndex, activeRemoteControlIndex);
                dispatchRemoteAction(control);
                if (!remoteVisible || remotePageIndex != activeRemoteTouchPage) {
                    activeRemoteControlIndex = -1;
                    activeRemoteControlVisual = false;
                    return;
                }
            }

            if (touch.wasReleased()) {
                const int8_t releasedControlIndex = activeRemoteControlIndex;
                const bool shouldActivate = insideCapturedControl && !activeRemoteHoldTriggered;
                if (activeRemoteControlVisual && control.kind == 0) {
                    displayRemoteControlFeedback(releasedControlIndex, false);
                }
                if (control.slider) {
                    displayRemoteSliderValue(page, releasedControlIndex, true);
                    if (control.action.value != activeRemoteSliderSentValue) {
                        dispatchRemoteAction(control);
                    }
                    persistRemoteSliderPositions(*remoteProfile);
                    refreshReferencedTextBoxes(page, control.id);
                }
                activeRemoteControlIndex = -1;
                activeRemoteControlVisual = false;
                if (shouldActivate && control.kind == 2) {
                    if (control.tapBehavior == 1) {
                        control.nextRefreshAt = millis();
                    } else if (control.tapBehavior == 2) {
                        dispatchRemoteAction(control);
                    }
                } else if (shouldActivate && !control.slider) {
                    Serial.printf("Remote control released: page=%u index=%d\n",
                        remotePageIndex, releasedControlIndex);
                    const bool succeeded = dispatchRemoteAction(control);
                    if (succeeded && control.toggle && remoteVisible &&
                        remotePageIndex == activeRemoteTouchPage) {
                        control.toggleOn = !control.toggleOn;
                        displayRemoteSliderValue(page, releasedControlIndex, true);
                        persistRemoteToggleStates(*remoteProfile);
                        refreshReferencedTextBoxes(page, control.id);
                    }
                }
                activeRemoteHoldTriggered = false;
            }
            return;
        }

        if (touch.wasClicked()) {
            if (touch.y < 106) {
                displaySettings();
            } else if (touch.y >= 850) {
                navigateRemote(touch.x < kDisplayWidth / 2 ? -1 : 1);
            }
        }
        return;
    }

    if (!touch.wasClicked()) {
        return;
    }

    if (settingsVisible) {
        if (touch.y < 120 && touch.x >= 430) {
            lastRemoteActivityAt = millis();
            displayRemote();
        } else if (touch.y >= 150 && touch.y < 292) {
            showLibrary();
        } else if (touch.y >= 312 && touch.y < 454) {
            displaySlideshowMenu();
        } else if (touch.y >= 474 && touch.y < 616) {
            if (wifiActive) {
                stopWifiMode();
                displaySettings();
            } else {
                startWifiMode();
            }
        }
        return;
    }

    if (wifiModeVisible) {
        if (touch.y < 120 && touch.x >= 430) {
            closeWifiMode();
        }
        return;
    }

    if (slideshowMenuVisible) {
        if (touch.y < 120 && touch.x >= 430) {
            closeSlideshowMenu();
        } else if (touch.y >= 130 && touch.y < 234) {
            slideshowEnabled = !slideshowEnabled;
            persistSettings();
            displaySlideshowMenu();
        } else if (touch.y >= 250 && touch.y < 354) {
            slideshowDeepSleep = !slideshowDeepSleep;
            persistSettings();
            displaySlideshowMenu();
        } else if (touch.y >= 370 && touch.y < 474 && touch.x >= 250 && touch.x < 350) {
            adjustScreensaverDelay(-1);
        } else if (touch.y >= 370 && touch.y < 474 && touch.x >= 430) {
            adjustScreensaverDelay(1);
        } else if (touch.y >= 490 && touch.y < 594 && touch.x >= 250 && touch.x < 350) {
            adjustSlideshowInterval(-1);
        } else if (touch.y >= 490 && touch.y < 594 && touch.x >= 430) {
            adjustSlideshowInterval(1);
        }
        return;
    }

    if (!libraryVisible) {
        if (remoteProfile != nullptr && remoteProfile->configured) {
            lastRemoteActivityAt = millis();
            displayRemote();
        } else {
            showLibrary();
        }
        return;
    }

    if (touch.y < 120 && touch.x >= 430) {
        libraryVisible = false;
        recoveredFromRenderCrash = false;
        if (remoteProfile != nullptr && remoteProfile->configured) {
            displaySettings();
        } else if (animationReady) {
            stillFrameDisplayed = false;
            displayedFrames = 0;
            nextFrameAt = millis();
        } else {
            splashPending = true;
        }
        return;
    }

    constexpr int32_t rowTop = 166;
    constexpr int32_t rowHeight = 88;
    if (touch.y >= rowTop && touch.y < rowTop + rowHeight * kLibraryRowsPerPage) {
        const size_t row = static_cast<size_t>((touch.y - rowTop) / rowHeight);
        selectLibraryItem(libraryPage * kLibraryRowsPerPage + row);
        return;
    }

    const size_t pageCount = max(static_cast<size_t>(1),
        (libraryItemCount + kLibraryRowsPerPage - 1) / kLibraryRowsPerPage);
    if (touch.y >= 830 && touch.x < 190 && libraryPage > 0) {
        --libraryPage;
        librarySelection = libraryPage * kLibraryRowsPerPage;
        displayLibrary();
    } else if (touch.y >= 830 && touch.x > 350 && libraryPage + 1 < pageCount) {
        ++libraryPage;
        librarySelection = libraryPage * kLibraryRowsPerPage;
        displayLibrary();
    }
}

void expandLegacyFrameRows() {
    for (int32_t row = kDisplayHeight - 1; row >= 0; --row) {
        for (int32_t column = kDisplayWidth - 1; column >= 0; --column) {
            const uint32_t sourceBit = static_cast<uint32_t>(row) * kDisplayWidth + column;
            const bool isBlack = (frameBuffer[sourceBit / 8] & (0x80 >> (sourceBit % 8))) != 0;
            const uint32_t destinationBit = static_cast<uint32_t>(row) * kFrameBytesPerRow * 8 + column;
            const uint8_t mask = 0x80 >> (destinationBit % 8);
            if (isBlack) {
                frameBuffer[destinationBit / 8] |= mask;
            } else {
                frameBuffer[destinationBit / 8] &= ~mask;
            }
        }
        frameBuffer[static_cast<uint32_t>(row) * kFrameBytesPerRow + kFrameBytesPerRow - 1] &= 0xF0;
    }
}

bool changedFrameBounds(int32_t& x, int32_t& y, int32_t& width, int32_t& height) {
    if (!previousFrameValid || previousFrameBuffer == nullptr) {
        x = 0;
        y = 0;
        width = kDisplayWidth;
        height = kDisplayHeight;
        return true;
    }

    const int32_t bytesPerRow = animationHeader.grayscale
        ? kGrayscaleFrameBytesPerRow
        : kFrameBytesPerRow;
    const int32_t pixelsPerByte = animationHeader.grayscale ? 2 : 8;
    int32_t leftByte = bytesPerRow;
    int32_t rightByte = -1;
    int32_t top = kDisplayHeight;
    int32_t bottom = -1;
    for (int32_t row = 0; row < kDisplayHeight; ++row) {
        const uint32_t rowOffset = static_cast<uint32_t>(row) * bytesPerRow;
        for (int32_t byte = 0; byte < bytesPerRow; ++byte) {
            if (frameBuffer[rowOffset + byte] == previousFrameBuffer[rowOffset + byte]) {
                continue;
            }
            leftByte = min(leftByte, byte);
            rightByte = max(rightByte, byte);
            top = min(top, row);
            bottom = max(bottom, row);
        }
    }
    if (rightByte < 0) {
        return false;
    }

    x = leftByte * pixelsPerByte;
    y = top;
    width = min<int32_t>(kDisplayWidth, (rightByte + 1) * pixelsPerByte) - x;
    height = bottom - top + 1;
    return true;
}

void displayCurrentFrame() {
    if (!animationReady || upload.active) {
        return;
    }

    const uint32_t renderStartedAt = millis();
    renderInProgress = kRenderMarker;
    const uint32_t frameOffset = animationHeader.framesOffset +
        static_cast<uint32_t>(currentFrame) * animationHeader.frameBytes;
    if (!animationFile.seek(frameOffset) ||
        animationFile.read(frameBuffer, animationHeader.frameBytes) != animationHeader.frameBytes) {
        renderInProgress = 0;
        closeAnimation();
        return;
    }
    if (animationHeader.frameBytes == kLegacyFrameBytes) {
        expandLegacyFrameRows();
    }
    const uint32_t readFinishedAt = millis();

    const bool cleanRefresh = displayedFrames == 0 ||
        (animationHeader.adaptiveCleaning &&
         displayedFrames % animationHeader.cleanRefreshInterval == 0);
    int32_t dirtyX = 0;
    int32_t dirtyY = 0;
    int32_t dirtyWidth = kDisplayWidth;
    int32_t dirtyHeight = kDisplayHeight;
    const bool frameChanged = changedFrameBounds(dirtyX, dirtyY, dirtyWidth, dirtyHeight);
    const epd_mode_t transitionMode = animationHeader.transitionScans == 1
        ? epd_mode_t::epd_fastest
        : epd_mode_t::epd_fast;
    const bool useGrayscaleWaveform = animationHeader.grayscale && animationHeader.frameCount == 1;
    const epd_mode_t contentMode = useGrayscaleWaveform
        ? epd_mode_t::epd_text
        : transitionMode;
    if (cleanRefresh) {
        M5.Display.setEpdMode(epd_mode_t::epd_quality);
        M5.Display.fillScreen(TFT_WHITE);
        M5.Display.waitDisplay();
    }
    M5.Display.setEpdMode(contentMode);
    if (cleanRefresh || frameChanged) {
        if (!cleanRefresh) {
            M5.Display.setClipRect(dirtyX, dirtyY, dirtyWidth, dirtyHeight);
        }
        if (animationHeader.grayscale) {
            M5.Display.pushImage(
                0,
                0,
                kDisplayWidth,
                kDisplayHeight,
                frameBuffer,
                lgfx::color_depth_t::grayscale_4bit,
                kGrayscalePalette);
        } else {
            M5.Display.drawBitmap(0, 0, frameBuffer, kDisplayWidth, kDisplayHeight, TFT_BLACK, TFT_WHITE);
        }
        M5.Display.clearClipRect();
    }
    const uint32_t drawFinishedAt = millis();
    std::swap(frameBuffer, previousFrameBuffer);
    previousFrameValid = true;
    renderInProgress = 0;

    if (displayedFrames % 30 == 0) {
        const uint32_t dirtyPixels = cleanRefresh || !frameChanged
            ? (cleanRefresh ? kDisplayWidth * kDisplayHeight : 0)
            : static_cast<uint32_t>(dirtyWidth) * dirtyHeight;
        Serial.printf(
            "Frame %u: read=%lums draw=%lums total=%lums dirty=%lu%% mode=%s\n",
            currentFrame,
            static_cast<unsigned long>(readFinishedAt - renderStartedAt),
            static_cast<unsigned long>(drawFinishedAt - readFinishedAt),
            static_cast<unsigned long>(drawFinishedAt - renderStartedAt),
            static_cast<unsigned long>(dirtyPixels * 100 / (kDisplayWidth * kDisplayHeight)),
            cleanRefresh
                ? (useGrayscaleWaveform
                    ? "white+GL16"
                    : (animationHeader.transitionScans == 1 ? "white+DU4" : "white+DU"))
                : (useGrayscaleWaveform
                    ? "GL16"
                    : (animationHeader.transitionScans == 1 ? "DU4" : "DU")));
    }

    const uint16_t duration = frameDurations[currentFrame];
    currentFrame = (currentFrame + 1) % animationHeader.frameCount;
    ++displayedFrames;
    stillFrameDisplayed = animationHeader.frameCount == 1;
    nextFrameAt += duration;
    const uint32_t now = millis();
    while (animationHeader.frameCount > 1 &&
           static_cast<int32_t>(now - nextFrameAt) >= 0) {
        nextFrameAt += frameDurations[currentFrame];
        currentFrame = (currentFrame + 1) % animationHeader.frameCount;
    }

    if ((remoteProfile == nullptr || !remoteProfile->configured) &&
        slideshowEnabled && slideshowDeepSleep && !deepSleepSuspended &&
        animationHeader.frameCount == 1) {
        Serial.println("Sleeping until the next slideshow image");
        Serial.flush();
        esp_sleep_enable_timer_wakeup(slideshowIntervalUs());
        esp_sleep_enable_ext1_wakeup(1ULL << kMenuButtonPin, ESP_EXT1_WAKEUP_ALL_LOW);
        esp_deep_sleep_start();
    }
}

}  // namespace

void IRAM_ATTR handleTouchInterrupt() {
    touchInterruptPending = true;
}

void handleWifiEvent(WiFiEvent_t event, WiFiEventInfo_t info) {
    if (event == ARDUINO_EVENT_WIFI_AP_START) {
        wifiApStarted = true;
        Serial.println("Wi-Fi AP started");
    } else if (event == ARDUINO_EVENT_WIFI_AP_STOP) {
        wifiApStarted = false;
        wifiApStopping = false;
        Serial.println("Wi-Fi AP stopped");
    } else if (event == ARDUINO_EVENT_WIFI_STA_GOT_IP) {
        homeWifiConnecting = false;
        homeWifiAuthenticationRetryPending = false;
        homeWifiAuthenticationFailures = 0;
        homeWifiState = 2;
        homeWifiFailureReason = 0;
        homeWifiStatusChanged = true;
        homeWifiNotificationPending = true;
        Serial.printf("Home Wi-Fi connected: %s\n", WiFi.localIP().toString().c_str());
    } else if (event == ARDUINO_EVENT_WIFI_STA_DISCONNECTED) {
        const uint16_t reason = info.wifi_sta_disconnected.reason;
        homeWifiConnecting = false;
        homeWifiAttemptedAt = millis();
        if (isHomeWifiAuthenticationFailure(reason) &&
            ++homeWifiAuthenticationFailures < kHomeWifiAuthenticationAttemptLimit) {
            homeWifiState = 1;
            homeWifiFailureReason = 0;
            homeWifiAuthenticationRetryPending = true;
            homeWifiAuthenticationRetryRequestedAt = homeWifiAttemptedAt;
            homeWifiStatusChanged = true;
            homeWifiNotificationPending = true;
            Serial.printf("Home Wi-Fi authentication interrupted (reason %u), retry %u/%u\n",
                reason,
                homeWifiAuthenticationFailures + 1,
                kHomeWifiAuthenticationAttemptLimit);
            return;
        }
        if (!isHomeWifiAuthenticationFailure(reason)) {
            homeWifiAuthenticationFailures = 0;
        }
        homeWifiState = 3;
        homeWifiFailureReason = reason;
        homeWifiStatusChanged = true;
        homeWifiNotificationPending = true;
        Serial.printf("Home Wi-Fi disconnected: reason %u\n", homeWifiFailureReason);
    }
}

void setup() {
    Serial.begin(115200);
    homeWifiSessionToken = static_cast<uint64_t>(esp_random()) << 32 | esp_random();
    if (homeWifiSessionToken == 0) {
        homeWifiSessionToken = 1;
    }
    WiFi.onEvent(handleWifiEvent);
    wakeupCause = esp_sleep_get_wakeup_cause();
    recoveredFromRenderCrash = renderInProgress == kRenderMarker;
    renderInProgress = 0;
    Serial.printf("Reset reason: %d, render recovery: %s\n",
        static_cast<int>(esp_reset_reason()), recoveredFromRenderCrash ? "yes" : "no");

    auto config = M5.config();
    M5.begin(config);
    M5.Display.setRotation(0);
    pinMode(36, INPUT_PULLUP);
    attachInterrupt(digitalPinToInterrupt(36), handleTouchInterrupt, FALLING);
    Serial.printf("Display: %d x %d\n", M5.Display.width(), M5.Display.height());

    remoteProfile = static_cast<RemoteProfile*>(heap_caps_calloc(
        1, sizeof(RemoteProfile), MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
    pendingRemoteProfile = static_cast<RemoteProfile*>(heap_caps_calloc(
        1, sizeof(RemoteProfile), MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
    if (remoteProfile == nullptr || pendingRemoteProfile == nullptr) {
        Serial.println("Remote profile PSRAM allocation failed");
    } else {
        initializeDefaultRemoteProfile();
    }

    sdReady = initializeSdCard();
    if (!sdReady) {
        M5.Display.setEpdMode(epd_mode_t::epd_quality);
        M5.Display.fillScreen(TFT_WHITE);
        M5.Display.setTextColor(TFT_BLACK, TFT_WHITE);
        M5.Display.setFont(&fonts::FreeSansBold18pt7b);
        M5.Display.setTextSize(1);
        M5.Display.drawCenterString("SD card unavailable", M5.Display.width() / 2, M5.Display.height() / 2);
    } else {
        SD.mkdir(kLibraryDirectory);
        restoreActiveSelection();
        restoreSettings();
        loadRemoteProfile();
    }

    frameBuffer = static_cast<uint8_t*>(heap_caps_malloc(
        kGrayscaleFrameBytes, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
    if (frameBuffer == nullptr) {
        frameBuffer = static_cast<uint8_t*>(malloc(kGrayscaleFrameBytes));
    }

    previousFrameBuffer = static_cast<uint8_t*>(heap_caps_malloc(
        kGrayscaleFrameBytes, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
    if (previousFrameBuffer == nullptr) {
        previousFrameBuffer = static_cast<uint8_t*>(malloc(kGrayscaleFrameBytes));
    }

    if (frameBuffer != nullptr && previousFrameBuffer != nullptr) {
        loadAnimation();
        refreshLibrary();
        if (wakeupCause == ESP_SLEEP_WAKEUP_TIMER && slideshowEnabled) {
            prepareNextSlideshowItem();
        }
    }
    pinMode(kPreviousButtonPin, INPUT);
    pinMode(kMenuButtonPin, INPUT);
    pinMode(kNextButtonPin, INPUT);
    if (wakeupCause == ESP_SLEEP_WAKEUP_EXT1) {
        menuButton.rawPressed = true;
        menuButton.pressed = true;
        menuButton.changedAt = millis();
    }
    startBluetooth();
    if (remoteProfile != nullptr && remoteProfile->configured) {
        lastRemoteActivityAt = millis();
        displayRemote();
        connectHomeWifi();
    } else if (recoveredFromRenderCrash && sdReady) {
        libraryPage = 0;
        displayLibrary();
    } else if (wakeupCause == ESP_SLEEP_WAKEUP_EXT1 && sdReady) {
        displaySlideshowMenu();
    }
}

void loop() {
    M5.update();
    handleSideButtons();
    handleTouch();
    if (wifiScanRequested && !upload.active && !remoteProfileUpload.active) {
        scanWifiNetworks();
    }
    if (wifiStartRequested && !wifiActive && !wifiApStopping &&
        millis() - wifiStartRequestedAt >= 500) {
        wifiStartRequested = false;
        startWifiMode(false);
    }
    if (wifiServerRunning) {
        wifiServer.handleClient();
    }
    if (bluetoothSuspendRequested && !upload.active &&
        millis() - bluetoothSuspendRequestedAt >= 250) {
        suspendBluetoothForWifiUpload();
    }
    if (bluetoothResumeRequested && !upload.active) {
        resumeBluetoothAfterWifiUpload();
    }
    if (bluetoothSuspendedForWifiUpload && !upload.active &&
        millis() - bluetoothSuspendedAt >= 10000) {
        bluetoothResumeRequested = true;
    }
    if (wifiActive) {
        if (wifiScreenRefreshPending && !upload.active) {
            wifiScreenRefreshPending = false;
            if (wifiModeVisible) {
                displayWifiMode();
            } else if (libraryVisible) {
                displayLibrary();
            }
        }
    }
    if (homeWifiStatusChanged) {
        homeWifiStatusChanged = false;
        if (homeWifiState == 2) {
            startWifiServer();
        } else if (!wifiActive) {
            stopWifiServer();
        }
        if (remoteVisible) {
            displayRemote();
        }
    }
    if (homeWifiNotificationPending && deviceConnected) {
        homeWifiNotificationPending = false;
        notifyHomeWifiStatus();
    }
    if (remoteVisible && remoteActionStatus[0] != '\0' &&
        static_cast<int32_t>(millis() - remoteActionStatusClearAt) >= 0) {
        remoteActionStatus[0] = '\0';
        remoteActionStatusClearAt = 0;
        M5.Display.setEpdMode(epd_mode_t::epd_fastest);
        M5.Display.startWrite();
        drawRemoteStatusLine();
        M5.Display.endWrite();
    }
    if (remoteVisible && millis() - remoteBatterySampledAt >= 60000) {
        refreshRemoteBatteryIndicator();
    }
    pollRemoteTextBoxes();
    if (homeWifiAuthenticationRetryPending &&
        millis() - homeWifiAuthenticationRetryRequestedAt >= kHomeWifiAuthenticationRetryDelayMs) {
        homeWifiAuthenticationRetryPending = false;
        connectHomeWifi();
    }
    if (remoteProfile != nullptr && remoteProfile->configured && !wifiActive &&
        WiFi.status() != WL_CONNECTED && !homeWifiConnecting &&
        !homeWifiAuthenticationRetryPending &&
        millis() - homeWifiAttemptedAt >= 30000) {
        homeWifiAuthenticationFailures = 0;
        connectHomeWifi();
    }
    if (homeWifiConnecting && millis() - homeWifiAttemptedAt >= 15000) {
        homeWifiConnecting = false;
        homeWifiState = 3;
        homeWifiFailureReason = 0;
        homeWifiStatusChanged = true;
        homeWifiNotificationPending = true;
        Serial.println("Home Wi-Fi connection timed out");
        if (remoteVisible) {
            displayRemote();
        }
    }
    if (wifiStopRequested && wifiActive && millis() - wifiStopRequestedAt >= 250) {
        wifiStopRequested = false;
        stopWifiMode();
    }
    if (upload.active) {
        const uint32_t now = millis();
        if (uploadScreenPending) {
            uploadScreenPending = false;
            displayUploadStart();
        } else if (now - upload.lastActivityAt >= 20000) {
            cancelUpload(!wifiActive);
            loadAnimation();
            if (wifiActive) {
                wifiUploadFailed = true;
                wifiScreenRefreshPending = true;
            }
        } else if (wifiUploadStartedAt == 0 &&
               pendingUploadProgress > displayedUploadProgress &&
                   (pendingUploadProgress == 100 || now - lastProgressDisplayAt >= 500)) {
            displayUploadProgress(pendingUploadProgress);
        }
    }
    if (remoteProfileUpload.active &&
        millis() - remoteProfileUpload.lastActivityAt >= 20000) {
        cancelRemoteProfileUpload(true);
    }

    if (!upload.active && !remoteProfileUpload.active && remoteVisible &&
        remoteProfile != nullptr && slideshowEnabled && animationReady &&
        millis() - lastRemoteActivityAt >= screensaverDelayMs()) {
        remoteVisible = false;
        screensaverActive = true;
        stillFrameDisplayed = false;
        displayedFrames = 0;
        nextFrameAt = millis();
        nextSlideshowAt = millis() + slideshowIntervalMs();
    }

    if (!upload.active && !remoteProfileUpload.active && !remoteVisible &&
        !settingsVisible && !libraryVisible && !slideshowMenuVisible && !wifiModeVisible &&
        !animationReady && splashPending) {
        displayDisconnectedSplash();
    } else if (!upload.active && !remoteProfileUpload.active && !remoteVisible &&
        !settingsVisible && !libraryVisible && !slideshowMenuVisible && !wifiModeVisible &&
        (slideshowEnabled || screensaverActive) && animationReady &&
        static_cast<int32_t>(millis() - nextSlideshowAt) >= 0) {
        navigatePlayback(1);
    } else if (!upload.active && !remoteProfileUpload.active && !remoteVisible &&
        !settingsVisible && !libraryVisible && !slideshowMenuVisible && !wifiModeVisible && animationReady &&
        !stillFrameDisplayed &&
        static_cast<int32_t>(millis() - nextFrameAt) >= 0) {
        displayCurrentFrame();
    }
    delay(1);
}