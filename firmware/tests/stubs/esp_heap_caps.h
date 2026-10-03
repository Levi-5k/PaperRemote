#pragma once

// Host-test substitute only; firmware builds use the ESP32 SDK header.
#include <cstddef>
#include <cstdint>

constexpr uint32_t MALLOC_CAP_8BIT = 1U << 2;
constexpr uint32_t MALLOC_CAP_SPIRAM = 1U << 10;

void* heap_caps_malloc(size_t size, uint32_t capabilities);
void heap_caps_free(void* pointer);
void* heap_caps_realloc(void* pointer, size_t size, uint32_t capabilities);