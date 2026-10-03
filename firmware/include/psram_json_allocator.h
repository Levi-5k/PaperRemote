#pragma once

#include <ArduinoJson.h>
#include <esp_heap_caps.h>

// Profile trees contain many small strings and nodes. The default allocator
// puts those in internal RAM, starving Wi-Fi buffers even when PSRAM is free.
// Deliberately do not fall back to internal RAM on allocation failure.
class PsramJsonAllocator final : public ArduinoJson::Allocator {
public:
    void* allocate(size_t size) override {
        return heap_caps_malloc(size, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    }

    void deallocate(void* pointer) override {
        heap_caps_free(pointer);
    }

    void* reallocate(void* pointer, size_t size) override {
        return heap_caps_realloc(pointer, size, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    }
};