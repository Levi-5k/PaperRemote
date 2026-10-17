#pragma once

#include <Arduino.h>
#include <Wire.h>
#include "board_driver.h"

#ifndef PAPERGIF_SUPERMINI_BUTTON_1_PIN
#define PAPERGIF_SUPERMINI_BUTTON_1_PIN 11
#endif
#ifndef PAPERGIF_SUPERMINI_BUTTON_2_PIN
#define PAPERGIF_SUPERMINI_BUTTON_2_PIN 10
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
    uint32_t sequence = 0, dialAt = 0;
    uint16_t lastAngle = 0;
    bool hasAngle = false;

    bool readAngle(uint16_t& angle) {
        Wire.beginTransmission(mt6701Address);
        Wire.write(mt6701AngleHighRegister);
        if (Wire.endTransmission(false) != 0 || Wire.requestFrom(mt6701Address, uint8_t(2)) != 2)
            return false;
        const int high = Wire.read();
        const int low = Wire.read();
        if (high < 0 || low < 0) return false;
        angle = uint16_t((high << 6) | ((low >> 2) & 0x3f));
        return true;
    }

public:
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
        hasAngle = readAngle(lastAngle);
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

        if (now - dialAt < 20) return false;
        dialAt = now;
        uint16_t angle = 0;
        if (!readAngle(angle)) return false;
        if (!hasAngle) {
            lastAngle = angle;
            hasAngle = true;
            return false;
        }
        int delta = int(angle) - int(lastAngle);
        if (delta > 8192) delta -= 16384;
        else if (delta < -8192) delta += 16384;
        if (std::abs(delta) < 4) return false;
        lastAngle = angle;
        event = {"dial-1", "change", double(angle), ++sequence};
        return true;
    }

    void release() override {
        for (auto& button : buttons) {
            button.down = false;
            button.held = false;
            button.blocked = true;
        }
        hasAngle = false;
    }
};

class SuperMiniS3Board final : public BoardDriver {
    SuperMiniS3Inputs input;
public:
    const BoardInfo& info() const override { return superminiS3Mt6701(); }
    DisplayDriver* display() override { return nullptr; }
    InputDriver* inputs() override { return &input; }
    bool readDialForDiagnostics(uint16_t& angle) { return input.readDialForDiagnostics(angle); }
    bool buttonPressedForDiagnostics(size_t index) const {
        return input.buttonPressedForDiagnostics(index);
    }
};
}