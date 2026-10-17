#pragma once
#include "board_driver.h"
#include "generic_display_layout.h"

namespace paper_board {
class SimulatedDisplay final : public DisplayDriver {
    DisplayInfo geometry;
public:
    Rect drawn[128]{};
    size_t count = 0;
    bool initialized = false;
    unsigned frames = 0;
    explicit SimulatedDisplay(int width, int height, int rotation = 0)
        : geometry{width, height, true, "rgb565", rotation} {}
    const DisplayInfo* info() const override { return &geometry; }
    void begin() override { initialized = true; }
    void drawControl(const char*, const Rect& pixels) override {
        if (count < 128) drawn[count++] = pixels;
    }
    void present() override { ++frames; }
    int hit(double x, double y) const {
        for (size_t i = 0; i < count; ++i) if (contains(drawn[i], x, y)) return int(i);
        return -1;
    }
    void layout(const Rect& logical, const Rect* controls, size_t length) {
        count = 0;
        const Rect viewport{0, 0, double(geometry.width), double(geometry.height)};
        const Rect fitted = fit(logical, viewport);
        for (size_t i = 0; i < length; ++i)
            drawControl("", project(controls[i], logical, fitted));
        present();
    }
    void layoutGrid(unsigned columns, unsigned rows, const unsigned* slots, size_t length) {
        count = 0;
        const Rect viewport{0, 0, double(geometry.width), double(geometry.height)};
        for (size_t i = 0; i < length; ++i)
            drawControl("", genericControlRect(viewport, columns, rows, slots[i]));
        present();
    }
};
class SimulatedInputs final : public InputDriver {
    InputEvent queued[128]{};
    size_t head = 0, tail = 0;
public:
    bool initialized = false, released = false;
    void begin() override { initialized = true; }
    bool push(InputEvent event) {
        if (tail >= 128) return false;
        queued[tail++] = event; return true;
    }
    bool poll(InputEvent& event) override {
        if (head == tail) return false;
        event = queued[head++]; return true;
    }
    void release() override { head = tail; released = true; }
};
class SimulatedBoard final : public BoardDriver {
    BoardInfo board;
    SimulatedDisplay* panel;
public:
    SimulatedInputs input;
    explicit SimulatedBoard(SimulatedDisplay* display) : board(esp32Reference()), panel(display) {
        board.display = panel ? panel->info() : nullptr;
    }
    const BoardInfo& info() const override { return board; }
    DisplayDriver* display() override { return panel; }
    InputDriver* inputs() override { return &input; }
};
}
