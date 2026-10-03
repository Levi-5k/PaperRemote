#pragma once

#include <Arduino.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>

namespace render_diagnostics {

enum class Stage : uint8_t { idle, initializing, readingFrame, clearing, waitingClear, drawingFrame };
static volatile Stage stage = Stage::idle;
static volatile uint32_t startedAt = 0;

inline const char* name(Stage value) {
    switch (value) {
        case Stage::initializing: return "M5.begin";
        case Stage::readingFrame: return "SD frame read";
        case Stage::clearing: return "panel white fill";
        case Stage::waitingClear: return "panel white refresh";
        case Stage::drawingFrame: return "panel image transfer";
        default: return "idle";
    }
}

inline void mark(Stage value) {
    startedAt = millis();
    stage = value;
}

inline void monitor(void*) {
    for (;;) {
        vTaskDelay(pdMS_TO_TICKS(5000));
        const Stage current = stage;
        const uint32_t elapsed = millis() - startedAt;
        if (current != Stage::idle && elapsed >= 5000) {
            // Read pins only; never contend for the stalled SPI/I2C bus.
            Serial.printf("Render stalled: stage=%s elapsed=%lu ms panelHRDY=%d touchIRQ=%d center=%d\n",
                name(current), static_cast<unsigned long>(elapsed),
                digitalRead(27), digitalRead(36), digitalRead(38));
        }
    }
}

inline void start() {
    xTaskCreatePinnedToCore(monitor, "render-watch", 2048, nullptr, tskIDLE_PRIORITY, nullptr, 0);
}

}  // namespace render_diagnostics