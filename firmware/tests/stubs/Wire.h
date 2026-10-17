#pragma once

#include <cstddef>
#include <cstdint>

class TwoWire {
public:
    void begin(int sda, int scl);
    void setClock(uint32_t frequency);
    void beginTransmission(uint8_t address);
    size_t write(uint8_t value);
    uint8_t endTransmission(bool stop = true);
    uint8_t requestFrom(uint8_t address, uint8_t size);
    int available();
    int read();
};

extern TwoWire Wire;