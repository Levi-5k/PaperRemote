#pragma once

#include <Arduino.h>
#include <Wire.h>
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
    Button buttons[2]{{PAPERGIF_SUPERMINI_BUTTON_1_PIN, "button-1"},
        {PAPERGIF_SUPERMINI_BUTTON_2_PIN, "button-2"}};
    uint32_t sequence = 0, dialAt = 0, sampleAt = 0, dialIntervalMicros = 5000;
    static constexpr uint32_t sampleIntervalMicros = 1000;
    AngleAverager average;
    DialTracker dial;
    bool sensorPresent = false;

    bool readAngle(uint16_t& angle) {
        Wire.beginTransmission(mt6701Address);
        Wire.write(mt6701AngleHighRegister);
        if (Wire.endTransmission(false) != 0 || Wire.requestFrom(mt6701Address, uint8_t(2)) != 2)
            return false;
        const int high = Wire.read();
        const int low = Wire.read();
        if (high < 0 || low < 0) return false;
        // The magnet sits above the sensor, so the raw angle grows counterclockwise from the
        // user's side; mirror it so turning the knob clockwise increases the angle.
        angle = uint16_t((16384 - ((high << 6) | ((low >> 2) & 0x3f))) & 0x3fff);
        return true;
    }

public:
    DialTracker& dialTracker() { return dial; }
    // Output period: readings within it are averaged into one tracker update.
    void setDialIntervalMicros(uint32_t interval) { dialIntervalMicros = interval < 1000 ? 1000 : interval; }
    bool dialPresent() const { return sensorPresent; }
    bool readDialForDiagnostics(uint16_t& angle) { return readAngle(angle); }
    bool buttonPressedForDiagnostics(size_t index) const {
        return index < 2 && digitalRead(buttons[index].pin) == LOW;
    }

    void begin() override {
        for (auto& button : buttons) {
            pinMode(button.pin, INPUT_PULLUP);
            button.raw = digitalRead(button.pin) == LOW;
            button.blocked = button.raw;
        }
        Wire.begin(PAPERGIF_MT6701_SDA_PIN, PAPERGIF_MT6701_SCL_PIN);
        Wire.setClock(400000);
        uint16_t angle = 0;
        sensorPresent = readAngle(angle);
        double ignored = 0;
        if (sensorPresent) dial.update(angle, ignored);
    }

    bool poll(InputEvent& event) override {
        const uint32_t now = millis();
        for (auto& button : buttons) {
            const bool raw = digitalRead(button.pin) == LOW;
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
        const uint32_t sampledAt = micros();
        if (sampledAt - sampleAt < sampleIntervalMicros) return false;
        sampleAt = sampledAt;
        uint16_t angle = 0;
        sensorPresent = readAngle(angle);
        if (!sensorPresent) { average.clear(); dial.resetSensor(); return false; }
        if (average.samples() == 0) dialAt = sampledAt;
        average.add(angle);
        if (sampledAt - dialAt < dialIntervalMicros) return false;
        double value = 0;
        if (!dial.update(average.take(), value)) return false;
        event = {"dial-1", "change", value, ++sequence,
            dial.configuration().mode == DialMode::continuous};
        return true;
    }

    void release() override {
        for (auto& button : buttons) {
            button.down = false;
            button.held = false;
            button.blocked = true;
        }
        // Losing a transport must not reset the dial's multi-turn position.
    }
};

class SuperMiniS3Board final : public BoardDriver {
    SuperMiniS3Inputs input;
public:
    const BoardInfo& info() const override { return superminiS3Mt6701(); }
    DisplayDriver* display() override { return nullptr; }
    InputDriver* inputs() override { return &input; }
    DialTracker& dialTracker() { return input.dialTracker(); }
    bool configureDial(const DialConfiguration& settings) {
        if (!input.dialTracker().configure(settings)) return false;
        // In low latency the averaging window is one send period, so each send
        // carries the mean of every reading since the previous one.
        input.setDialIntervalMicros(settings.lowLatency ? uint32_t(1e6 / settings.rate) : 5000);
        return true;
    }
    bool dialPresent() const { return input.dialPresent(); }
    bool readDialForDiagnostics(uint16_t& angle) { return input.readDialForDiagnostics(angle); }
    bool buttonPressedForDiagnostics(size_t index) const {
        return input.buttonPressedForDiagnostics(index);
    }
};
}