#pragma once

#include "board_hardware.h"
#include "board_driver.h"
#include "dial_tracker.h"

#ifndef PAPERGIF_SUPERMINI_BUTTON_1_PIN
#define PAPERGIF_SUPERMINI_BUTTON_1_PIN 10
#endif
#ifndef PAPERGIF_SUPERMINI_BUTTON_2_PIN
#define PAPERGIF_SUPERMINI_BUTTON_2_PIN 11
#endif
#ifndef PAPERGIF_MT6701_SDA_PIN
#define PAPERGIF_MT6701_SDA_PIN 13
#endif
#ifndef PAPERGIF_MT6701_SCL_PIN
#define PAPERGIF_MT6701_SCL_PIN 12
#endif

namespace paper_board {
constexpr uint8_t mt6701Address = 0x06;
constexpr uint8_t mt6701AngleHighRegister = 0x03;

class SuperMiniS3Inputs final : public InputDriver {
    struct Button {
        int pin;
        const char* id;
        bool raw = false, down = false, held = false, blocked = false;
        uint32_t changed = 0, pressed = 0;
        Button(int pinNumber, const char* identifier) : pin(pinNumber), id(identifier) {}
    };
    Button buttons[2];
    int sdaPin;
    int sclPin;
    uint32_t sequence = 0, dialAt = 0, sampleAt = 0, dialIntervalMicros = 5000;
    static constexpr uint32_t sampleIntervalMicros = 1000;
    static constexpr uint8_t queueCapacity = 8;
    InputEvent queued[queueCapacity]{};
    uint8_t queueHead = 0, queueCount = 0;
    AngleAverager average;
    DialTracker dial;
    bool sensorPresent = false;
    uint8_t dialMisses = 0;
#if defined(PAPERGIF_NATIVE_IDF)
    SemaphoreHandle_t sampleMutex = nullptr;
    TaskHandle_t sampleTask = nullptr;
    InputEventBuffer<32> sampledEvents;
    uint32_t droppedEvents = 0;
    uint32_t sampleCount = 0;
    bool overflowPending = false;
    class SampleLock {
        SemaphoreHandle_t mutex;
    public:
        explicit SampleLock(SemaphoreHandle_t value) : mutex(value) {
            if (mutex) xSemaphoreTake(mutex, portMAX_DELAY);
        }
        ~SampleLock() { if (mutex) xSemaphoreGive(mutex); }
    };
    static void sampleWorker(void* context) {
        auto* inputs = static_cast<SuperMiniS3Inputs*>(context);
        TickType_t wake = xTaskGetTickCount();
        for (;;) {
            {
                SampleLock lock(inputs->sampleMutex);
                ++inputs->sampleCount;
                InputEvent event;
                for (int count = 0; count < 8 && inputs->sample(event); ++count)
                    if (!inputs->overflowPending && !inputs->sampledEvents.push(event)) {
                        ++inputs->droppedEvents;
                        inputs->overflowPending = true;
                    }
            }
            vTaskDelayUntil(&wake, std::max(TickType_t(1), pdMS_TO_TICKS(1)));
        }
    }
#endif

    bool readAngle(uint16_t& angle) {
        // A CST820 poll shares this bus. One failed transaction must not look like a missing dial;
        // restart the controller and try once more before reporting the miss.
        for (int attempt = 0; attempt < 2; ++attempt) {
            if (attempt) {
                hardware::resetI2C();
                hardware::beginI2C(sdaPin, sclPin);
            }
            uint8_t bytes[2];
            if (!hardware::readRegister(mt6701Address, mt6701AngleHighRegister, bytes, sizeof(bytes))) continue;
            const int high = bytes[0];
            const int low = bytes[1];
            // The magnet sits above the sensor, so the raw angle grows counterclockwise from the
            // user's side; mirror it so turning the knob clockwise increases the angle.
            angle = uint16_t((16384 - ((high << 6) | ((low >> 2) & 0x3f))) & 0x3fff);
            return true;
        }
        return false;
    }

public:
    explicit SuperMiniS3Inputs(int button1 = PAPERGIF_SUPERMINI_BUTTON_1_PIN,
                               int button2 = PAPERGIF_SUPERMINI_BUTTON_2_PIN,
                               int sda = PAPERGIF_MT6701_SDA_PIN,
                               int scl = PAPERGIF_MT6701_SCL_PIN)
        : buttons{{button1, "button-1"}, {button2, "button-2"}}, sdaPin(sda), sclPin(scl) {}
    // Touch UI events share this driver's sequence and are returned before the next sample.
    bool enqueue(const char* id, const char* eventName, double value) {
#if defined(PAPERGIF_NATIVE_IDF)
        SampleLock lock(sampleMutex);
#endif
        if (!id || !eventName || queueCount >= queueCapacity) return false;
        const uint8_t slot = uint8_t((queueHead + queueCount) % queueCapacity);
        queued[slot] = InputEvent(id, eventName, value, ++sequence);
        ++queueCount;
        return true;
    }
#if defined(PAPERGIF_NATIVE_IDF)
    DialTracker dialTracker() { SampleLock lock(sampleMutex); return dial; }
    bool configureDial(const DialConfiguration& settings) {
        SampleLock lock(sampleMutex);
        if (!dial.configure(settings)) return false;
        dialIntervalMicros = settings.lowLatency ? uint32_t(1e6 / settings.rate) : 1000;
        sampledEvents.clear();
        return true;
    }
    void zeroDial() { SampleLock lock(sampleMutex); dial.zero(); sampledEvents.clear(); }
    void setRelativeDialOutput(bool enabled) {
        SampleLock lock(sampleMutex);
        if (dial.setRelativeOutput(enabled)) {
            sampledEvents.remove("dial-1");
            average.clear();
        }
    }
    void discardQueuedDial() {
        SampleLock lock(sampleMutex);
        sampledEvents.remove("dial-1");
        overflowPending = false;
    }
    uint32_t droppedInputEvents() { SampleLock lock(sampleMutex); return droppedEvents; }
    uint32_t inputSampleCount() { SampleLock lock(sampleMutex); return sampleCount; }
    uint32_t inputStackFreeBytes() { return sampleTask ? uxTaskGetStackHighWaterMark(sampleTask) : 0; }
#else
    DialTracker& dialTracker() { return dial; }
    void zeroDial() { dial.zero(); }
    void setRelativeDialOutput(bool enabled) { if (dial.setRelativeOutput(enabled)) average.clear(); }
#endif
    // Output period: readings within it are averaged into one tracker update.
    void setDialIntervalMicros(uint32_t interval) {
#if defined(PAPERGIF_NATIVE_IDF)
        SampleLock lock(sampleMutex);
#endif
        dialIntervalMicros = interval < 1000 ? 1000 : interval;
    }
    bool dialPresent() const {
#if defined(PAPERGIF_NATIVE_IDF)
        SampleLock lock(sampleMutex);
#endif
        return sensorPresent;
    }
    bool readDialForDiagnostics(uint16_t& angle) { return readAngle(angle); }
    bool buttonPressedForDiagnostics(size_t index) const {
        return index < 2 && hardware::pressed(buttons[index].pin);
    }

    void begin() override {
        for (auto& button : buttons) {
            hardware::inputPullup(button.pin);
            button.raw = hardware::pressed(button.pin);
            button.blocked = button.raw;
        }
        hardware::beginI2C(sdaPin, sclPin);
        uint16_t angle = 0;
        sensorPresent = readAngle(angle);
        double ignored = 0;
        if (sensorPresent) dial.update(angle, ignored);
#if defined(PAPERGIF_NATIVE_IDF)
        sampleMutex = xSemaphoreCreateMutex();
        if (!sampleMutex || xTaskCreatePinnedToCore(sampleWorker, "physical-input", 3072,
            this, 2, &sampleTask, 0) != pdPASS) abort();
#endif
    }

    bool poll(InputEvent& event) override {
#if defined(PAPERGIF_NATIVE_IDF)
        SampleLock lock(sampleMutex);
    if (overflowPending) {
        sampledEvents.clear();
        overflowPending = false;
        event = InputEvent("", "overflow", 0, ++sequence);
        return true;
    }
        return sampledEvents.pop(event);
#else
        return sample(event);
#endif
    }

private:
    bool sample(InputEvent& event) {
        if (queueCount) {
            event = queued[queueHead];
            queueHead = uint8_t((queueHead + 1) % queueCapacity);
            --queueCount;
            return true;
        }
        const uint32_t now = hardware::millisNow();
        for (auto& button : buttons) {
            const bool raw = hardware::pressed(button.pin);
            if (button.blocked) {
                if (!raw) button.blocked = false;
                continue;
            }
            if (raw != button.raw) {
                button.raw = raw;
                button.changed = now;
            }
            if (button.down != raw && now - button.changed >= 20) {
                button.down = raw;
                button.held = false;
                button.pressed = now;
                event = {button.id, raw ? "press" : "release", raw ? 1.0 : 0.0, ++sequence};
                return true;
            }
            if (button.down && !button.held && now - button.pressed >= 600) {
                button.held = true;
                event = {button.id, "hold", 1, ++sequence};
                return true;
            }
        }

        // Sample every ~1 ms and hand the tracker the mean once per output
        // period. The tracker only emits when the averaged position actually
        // moves, so a still dial stays silent; the window keeps running, so
        // the settled position after motion still goes out.
        const uint32_t sampledAt = hardware::microsNow();
        if (sampledAt - sampleAt < sampleIntervalMicros) return false;
        sampleAt = sampledAt;
        uint16_t angle = 0;
        if (!readAngle(angle)) {
            // One glitch used to clear the sensor and freeze the on-screen arc at "No dial".
            if (sensorPresent && ++dialMisses < 12) return false;
            sensorPresent = false;
            average.clear();
            dial.resetSensor();
            return false;
        }
        dialMisses = 0;
        sensorPresent = true;
        if (average.samples() == 0) dialAt = sampledAt;
        average.add(angle);
        if (sampledAt - dialAt < dialIntervalMicros) return false;
        double value = 0;
        if (!dial.update(average.take(), value)) return false;
        event = {"dial-1", "change", value, ++sequence,
            dial.relativeOutput()};
        return true;
    }

public:
    void release() override {
#if defined(PAPERGIF_NATIVE_IDF)
        SampleLock lock(sampleMutex);
        sampledEvents.clear();
        overflowPending = false;
#endif
        queueHead = 0;
        queueCount = 0;
        for (auto& button : buttons) {
            button.down = false;
            button.held = false;
            button.blocked = true;
        }
        // Losing a transport must not reset the dial's multi-turn position.
    }
};

class SuperMiniS3Board : public BoardDriver {
protected:
    SuperMiniS3Inputs input;
public:
    explicit SuperMiniS3Board(int button1 = PAPERGIF_SUPERMINI_BUTTON_1_PIN,
                              int button2 = PAPERGIF_SUPERMINI_BUTTON_2_PIN,
                              int sda = PAPERGIF_MT6701_SDA_PIN,
                              int scl = PAPERGIF_MT6701_SCL_PIN)
        : input(button1, button2, sda, scl) {}
    bool postInput(const char* id, const char* eventName, double value) {
        return input.enqueue(id, eventName, value);
    }
    const BoardInfo& info() const override { return superminiS3Mt6701(); }
    DisplayDriver* display() override { return nullptr; }
    InputDriver* inputs() override { return &input; }
#if defined(PAPERGIF_NATIVE_IDF)
    DialTracker dialTracker() { return input.dialTracker(); }
    uint32_t droppedInputEvents() { return input.droppedInputEvents(); }
    uint32_t inputSampleCount() { return input.inputSampleCount(); }
    uint32_t inputStackFreeBytes() { return input.inputStackFreeBytes(); }
#else
    DialTracker& dialTracker() { return input.dialTracker(); }
#endif
    void zeroDial() { input.zeroDial(); }
    void setRelativeDialOutput(bool enabled) { input.setRelativeDialOutput(enabled); }
    // A page swipe does not drain the dial. Drop motion sampled while it is moving
    // so the seek bar is not jumped by the backlog when the finger lifts.
    void discardGestureDial() {
#if defined(PAPERGIF_NATIVE_IDF)
        input.discardQueuedDial();
#else
        InputEvent event;
        for (int count = 0; count < 4 && input.poll(event); ++count)
            if (std::strcmp(event.inputID, "dial-1")) input.enqueue(event.inputID, event.event, event.value);
#endif
    }
    bool configureDial(const DialConfiguration& settings) {
#if defined(PAPERGIF_NATIVE_IDF)
        return input.configureDial(settings);
#else
        if (!input.dialTracker().configure(settings)) return false;
        // In low latency the averaging window is one send period, so each send
        // carries the mean of every reading since the previous one.
        input.setDialIntervalMicros(settings.lowLatency ? uint32_t(1e6 / settings.rate) : 5000);
        return true;
#endif
    }
    bool dialPresent() const { return input.dialPresent(); }
    bool readDialForDiagnostics(uint16_t& angle) { return input.readDialForDiagnostics(angle); }
    bool buttonPressedForDiagnostics(size_t index) const {
        return input.buttonPressedForDiagnostics(index);
    }
};
}