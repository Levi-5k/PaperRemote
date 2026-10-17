#pragma once
#include <M5Unified.h>
#include "board_driver.h"

namespace paper_board {
class M5PaperDisplay final : public DisplayDriver {
public:
    const DisplayInfo* info() const override { return m5paper().display; }
    void begin() override {
        auto config = M5.config();
        config.output_power = false;
        config.clear_display = false;
        M5.begin(config);
    }
    void drawControl(const char*, const Rect& pixels) override {
        M5.Display.fillRect(pixels.x, pixels.y, pixels.width, pixels.height, TFT_WHITE);
    }
    void present() override { M5.Display.display(); }
};
class M5PaperBoard final : public BoardDriver {
    M5PaperDisplay panel;
public:
    const BoardInfo& info() const override { return m5paper(); }
    DisplayDriver* display() override { return &panel; }
    // Touch, side buttons, power, and IT8951 refresh policy remain in the existing M5 backend.
    InputDriver* inputs() override { return nullptr; }
};
}
