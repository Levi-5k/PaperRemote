#pragma once

#include <cstdint>
#include <cstddef>
#include <cstdio>
#if defined(PAPERGIF_NATIVE_IDF)
#include <driver/gpio.h>
#include <driver/i2c_master.h>
#include <esp_timer.h>
#include <esp_heap_caps.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <freertos/semphr.h>
#else
#include <Arduino.h>
#include <Wire.h>
#endif

namespace paper_board {
namespace hardware {
#if defined(PAPERGIF_NATIVE_IDF)
struct I2CBus {
    i2c_master_bus_handle_t handle = nullptr;
    i2c_master_dev_handle_t devices[128]{};
    SemaphoreHandle_t mutex = nullptr;
};
inline I2CBus& i2c() { static I2CBus bus; return bus; }
inline bool beginI2C(int sda, int scl) {
    if (i2c().handle) return true;
    if (!i2c().mutex) i2c().mutex = xSemaphoreCreateMutex();
    if (!i2c().mutex) return false;
    i2c_master_bus_config_t config{};
    config.i2c_port = I2C_NUM_0;
    config.sda_io_num = static_cast<gpio_num_t>(sda);
    config.scl_io_num = static_cast<gpio_num_t>(scl);
    config.clk_source = I2C_CLK_SRC_DEFAULT;
    config.glitch_ignore_cnt = 7;
    config.flags.enable_internal_pullup = true;
    return i2c_new_master_bus(&config, &i2c().handle) == ESP_OK;
}
class I2CLock {
public:
    I2CLock() { if (i2c().mutex) xSemaphoreTake(i2c().mutex, portMAX_DELAY); }
    ~I2CLock() { if (i2c().mutex) xSemaphoreGive(i2c().mutex); }
};
inline i2c_master_dev_handle_t device(uint8_t address) {
    if (!i2c().handle || address >= 128) return nullptr;
    auto& handle = i2c().devices[address];
    if (!handle) {
        i2c_device_config_t config{};
        config.dev_addr_length = I2C_ADDR_BIT_LEN_7;
        config.device_address = address;
        config.scl_speed_hz = 400000;
        if (i2c_master_bus_add_device(i2c().handle, &config, &handle) != ESP_OK) return nullptr;
    }
    return handle;
}
inline bool readRegister(uint8_t address, uint8_t reg, uint8_t* data, size_t size) {
    I2CLock lock;
    auto handle = device(address);
    return handle && i2c_master_transmit_receive(handle, &reg, 1, data, size, 20) == ESP_OK;
}
inline bool writeRegister(uint8_t address, uint8_t reg, uint8_t value) {
    I2CLock lock;
    auto handle = device(address);
    const uint8_t data[] = {reg, value};
    return handle && i2c_master_transmit(handle, data, sizeof(data), 20) == ESP_OK;
}
inline void resetI2C() { I2CLock lock; if (i2c().handle) i2c_master_bus_reset(i2c().handle); }
inline void inputPullup(int pin) {
    gpio_config_t config{};
    config.pin_bit_mask = 1ULL << pin;
    config.mode = GPIO_MODE_INPUT;
    config.pull_up_en = GPIO_PULLUP_ENABLE;
    ESP_ERROR_CHECK(gpio_config(&config));
}
inline bool pressed(int pin) { return gpio_get_level(static_cast<gpio_num_t>(pin)) == 0; }
inline uint32_t microsNow() { return static_cast<uint32_t>(esp_timer_get_time()); }
inline uint32_t millisNow() { return static_cast<uint32_t>(esp_timer_get_time() / 1000); }
inline void wait(uint32_t milliseconds) { vTaskDelay(pdMS_TO_TICKS(milliseconds)); }
template <typename... Args> void log(const char* format, Args... args) { std::printf(format, args...); }
#else
inline bool beginI2C(int sda, int scl) {
    const bool ready = Wire.begin(sda, scl);
    Wire.setClock(400000);
    return ready;
}
inline bool readRegister(uint8_t address, uint8_t reg, uint8_t* data, size_t size) {
    Wire.beginTransmission(address);
    Wire.write(reg);
    if (Wire.endTransmission(false) != 0 || Wire.requestFrom(address, uint8_t(size)) != size) return false;
    for (size_t index = 0; index < size; ++index) data[index] = Wire.read();
    return true;
}
inline bool writeRegister(uint8_t address, uint8_t reg, uint8_t value) {
    Wire.beginTransmission(address);
    Wire.write(reg);
    Wire.write(value);
    return Wire.endTransmission() == 0;
}
inline void resetI2C() {}
inline void inputPullup(int pin) { pinMode(pin, INPUT_PULLUP); }
inline bool pressed(int pin) { return digitalRead(pin) == LOW; }
inline uint32_t microsNow() { return micros(); }
inline uint32_t millisNow() { return millis(); }
inline void wait(uint32_t milliseconds) { delay(milliseconds); }
template <typename... Args> void log(const char* format, Args... args) { Serial.printf(format, args...); }
#endif
}
}