#include "../include/psram_json_allocator.h"

#include <cassert>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <map>
#include <sstream>
#include <string>

namespace {
std::map<void*, size_t> allocations;
bool failAllocations = false;
size_t allocationCalls = 0;
size_t reallocationCalls = 0;
constexpr uint32_t expectedCapabilities = MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT;
}

void* heap_caps_malloc(size_t size, uint32_t capabilities) {
    assert(capabilities == expectedCapabilities);
    ++allocationCalls;
    if (failAllocations) {
        return nullptr;
    }
    void* pointer = std::malloc(size);
    assert(pointer != nullptr);
    allocations[pointer] = size;
    return pointer;
}

void heap_caps_free(void* pointer) {
    if (pointer != nullptr) {
        assert(allocations.erase(pointer) == 1);
    }
    std::free(pointer);
}

void* heap_caps_realloc(void* pointer, size_t size, uint32_t capabilities) {
    assert(capabilities == expectedCapabilities);
    ++reallocationCalls;
    if (failAllocations) {
        return nullptr;
    }
    if (size == 0) {
        heap_caps_free(pointer);
        return nullptr;
    }
    const auto previous = allocations.find(pointer);
    assert(pointer == nullptr || previous != allocations.end());
    void* replacement = std::realloc(pointer, size);
    assert(replacement != nullptr);
    if (previous != allocations.end()) {
        allocations.erase(previous);
    }
    allocations[replacement] = size;
    return replacement;
}

int main() {
    PsramJsonAllocator allocator;
    {
        auto* buffer = static_cast<char*>(allocator.allocate(16));
        std::strcpy(buffer, "preserved");
        buffer = static_cast<char*>(allocator.reallocate(buffer, 64));
        assert(std::strcmp(buffer, "preserved") == 0);
        failAllocations = true;
        assert(allocator.reallocate(buffer, 128) == nullptr);
        assert(std::strcmp(buffer, "preserved") == 0);
        assert(allocator.allocate(16) == nullptr);
        failAllocations = false;
        allocator.deallocate(buffer);
    }
    assert(allocations.empty());

    std::ostringstream source;
    source << "{\"version\":6,\"pages\":[";
    for (int page = 0; page < 4; ++page) {
        if (page != 0) source << ',';
        source << "{\"id\":\"page-" << page << "\",\"controls\":[";
        for (int control = 0; control < 16; ++control) {
            if (control != 0) source << ',';
            const int index = page * 16 + control;
            source << "{\"id\":\"control-" << index
                   << "\",\"title\":\"Control " << index
                   << "\",\"iconBitmap\":\"" << std::string(1022, 'A')
                   << static_cast<char>('A' + index / 16)
                   << static_cast<char>('A' + index % 16)
                   << "\",\"toggleOn\":false,\"action\":{\"type\":\"macMedia\",\"value\":0}}";
        }
        source << "]}";
    }
    source << "]}";
    assert(source.str().size() > 64 * 1024);

    for (int iteration = 0; iteration < 20; ++iteration) {
        {
            JsonDocument document(&allocator);
            std::istringstream input(source.str());
            assert(!deserializeJson(document, input));
            assert(document["pages"].size() == 4);
            assert(document["pages"][3]["controls"].size() == 16);
            JsonObject control = document["pages"][3]["controls"][15];
            control["toggleOn"] = true;
            control["action"]["value"] = 217;
            control["action"]["valueTenths"] = 225;
            assert(!document.overflowed());

            std::string output;
            output.reserve(measureJson(document));
            assert(serializeJson(document, output) == measureJson(document));
            JsonDocument restored(&allocator);
            assert(!deserializeJson(restored, output));
            assert(restored["pages"][3]["controls"][15]["toggleOn"] == true);
            assert(restored["pages"][3]["controls"][15]["action"]["value"] == 217);
            assert(restored["pages"][3]["controls"][15]["action"]["valueTenths"] == 225);
        }
        assert(allocations.empty());
    }
    {
        failAllocations = true;
        JsonDocument document(&allocator);
        const auto error = deserializeJson(document, source.str());
        assert(error == DeserializationError::NoMemory);
        assert(document.overflowed());
        failAllocations = false;
    }
    assert(allocations.empty());
    assert(allocationCalls > 100);
    assert(reallocationCalls > 1);
    std::cout << "PSRAM JSON allocator tests passed: capability routing, large profiles, "
                 "round trips, allocation failure and cleanup\n";
}