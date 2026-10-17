#pragma once

#include <Arduino.h>
#include "board_driver.h"

#ifndef PAPERGIF_BUTTON_PIN
#define PAPERGIF_BUTTON_PIN 25
#endif
#ifndef PAPERGIF_ENCODER_A_PIN
#define PAPERGIF_ENCODER_A_PIN 26
#endif
#ifndef PAPERGIF_ENCODER_B_PIN
#define PAPERGIF_ENCODER_B_PIN 27
#endif
#ifndef PAPERGIF_SLIDER_PIN
#define PAPERGIF_SLIDER_PIN 34
#endif

namespace paper_board {
class ReferenceInputs final : public InputDriver {
    struct Button {
        int pin;
        const char* id;
        bool raw = false, down = false, held = false, blocked = false;
        uint32_t changed = 0, pressed = 0;
        Button(int pinNumber, const char* identifier) : pin(pinNumber), id(identifier) {}
    };
    Button buttons[1]{{PAPERGIF_BUTTON_PIN, "button-1"}};
    uint32_t sequence = 0, sliderAt = 0;
    int slider = -1, encoder = 0, quarterSteps = 0;
public:
    void begin() override {
        for (auto& b : buttons) {
            pinMode(b.pin, INPUT_PULLUP);
            b.blocked = digitalRead(b.pin) == LOW;
        }
        pinMode(PAPERGIF_ENCODER_A_PIN, INPUT_PULLUP);
        pinMode(PAPERGIF_ENCODER_B_PIN, INPUT_PULLUP);
        pinMode(PAPERGIF_SLIDER_PIN, INPUT);
        encoder = (digitalRead(PAPERGIF_ENCODER_A_PIN) << 1) | digitalRead(PAPERGIF_ENCODER_B_PIN);
        slider = analogRead(PAPERGIF_SLIDER_PIN);
    }
    bool poll(InputEvent& event) override {
        const uint32_t now = millis();
        for (auto& b : buttons) {
            const bool raw = digitalRead(b.pin) == LOW;
            if (b.blocked) { if (!raw) b.blocked = false; continue; }
            if (raw != b.raw) { b.raw = raw; b.changed = now; }
            if (b.down != raw && now - b.changed >= 20) {
                b.down = raw; b.held = false; b.pressed = now;
                event = {b.id, raw ? "press" : "release", raw ? 1.0 : 0.0, ++sequence};
                return true;
            }
            if (b.down && !b.held && now - b.pressed >= 600) {
                b.held = true;
                event = {b.id, "hold", 1, ++sequence};
                return true;
            }
        }
        static constexpr int8_t quadrature[] = {0,-1,1,0, 1,0,0,-1, -1,0,0,1, 0,1,-1,0};
        const int next = (digitalRead(PAPERGIF_ENCODER_A_PIN) << 1) | digitalRead(PAPERGIF_ENCODER_B_PIN);
        quarterSteps += quadrature[(encoder << 2) | next];
        encoder = next;
        if (quarterSteps >= 4 || quarterSteps <= -4) {
            const int delta = quarterSteps / 4;
            quarterSteps %= 4;
            event = {"encoder-1", "rotate", double(delta), ++sequence};
            return true;
        }
        if (now - sliderAt >= 25) {
            sliderAt = now;
            const int nextSlider = analogRead(PAPERGIF_SLIDER_PIN);
            if (std::abs(nextSlider - slider) >= 16 || (nextSlider != slider && (nextSlider == 0 || nextSlider == 4095))) {
                slider = nextSlider;
                event = {"slider-1", "change", double(slider), ++sequence};
                return true;
            }
        }
        return false;
    }
    void release() override {
        for (auto& b : buttons) { b.down = false; b.held = false; b.blocked = true; }
        quarterSteps = 0;
    }
};
class ReferenceBoard final : public BoardDriver {
    ReferenceInputs input;
public:
    const BoardInfo& info() const override { return esp32Reference(); }
    DisplayDriver* display() override { return nullptr; }
    InputDriver* inputs() override { return &input; }
};
}
