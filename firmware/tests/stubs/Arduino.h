#pragma once
#include <cstdint>
#include <cstdlib>

constexpr int LOW = 0;
constexpr int INPUT = 1;
constexpr int INPUT_PULLUP = 2;
uint32_t millis();
uint32_t micros();
void pinMode(int pin, int mode);
int digitalRead(int pin);
int analogRead(int pin);
