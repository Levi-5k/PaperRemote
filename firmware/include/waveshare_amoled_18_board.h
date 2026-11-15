#pragma once

#include "supermini_s3_board.h"
#include "reference_pages.h"

// Waveshare ESP32-S3-Touch-AMOLED-1.8 V2. GPIO 12 is the LCD chip select, so the
// MT6701 cannot keep the SuperMini's SCL pin. It shares the board I2C bus instead.
// Override these if the dial is wired to a different free pair.
#ifndef PAPERGIF_AMOLED_BUTTON_1_PIN
#define PAPERGIF_AMOLED_BUTTON_1_PIN 17
#endif
#ifndef PAPERGIF_AMOLED_BUTTON_2_PIN
#define PAPERGIF_AMOLED_BUTTON_2_PIN 18
#endif
#ifndef PAPERGIF_AMOLED_MT6701_SDA_PIN
#define PAPERGIF_AMOLED_MT6701_SDA_PIN 15
#endif
#ifndef PAPERGIF_AMOLED_MT6701_SCL_PIN
#define PAPERGIF_AMOLED_MT6701_SCL_PIN 14
#endif

namespace paper_board {
void waveshareUiPoll(const WaveshareUiState& state);
bool waveshareUiGestureActive();
bool waveshareUiSliderHeld();

class WaveshareAmoled18Board : public SuperMiniS3Board {
    class Screen;
    Screen* screen = nullptr;
public:
    WaveshareAmoled18Board();
    ~WaveshareAmoled18Board() override;
    const BoardInfo& info() const override { return waveshareAmoled18V2(); }
    DisplayDriver* display() override;
    void displayDiagnostics(JsonObject json);
};
}
