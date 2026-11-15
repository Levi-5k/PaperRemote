#include "../idf/main/media_store.h"
#include "../include/screen_image.h"
#include <algorithm>
#include <cassert>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <unistd.h>
#include <vector>

void* heap_caps_malloc(size_t size, uint32_t) { return std::malloc(size); }
void heap_caps_free(void* pointer) { std::free(pointer); }
extern "C" int64_t esp_timer_get_time() { return 0; }
static uint8_t reply = 0;
namespace native_device {
bool notify(uint16_t, const uint8_t* bytes, size_t) { reply = bytes[0]; return true; }
}
int main() {
    char temporary[] = "/tmp/papergif-http-image-XXXXXX";
    assert(mkdtemp(temporary));
    const std::filesystem::path directory(temporary);
    native_device::MediaStore store(directory.string());
    store.begin(true, "", 1);
    std::vector<uint8_t> image(10 + 368 * 448 * 2);
    const uint8_t header[] = {'P', 'I', 'M', 'G', 1, 0, 112, 1, 192, 1};
    std::memcpy(image.data(), header, sizeof(header));
    const char* id = "11111111-1111-4111-8111-111111111111";
    const char* other = "22222222-2222-4222-8222-222222222222";
    const auto crc = screen_image::checksum(image.data(), image.size());
    size_t index = SIZE_MAX;
    assert(store.uploadHTTP(image.data(), image.size(), "../bad", "Image", crc, false, index) == 400);
    assert(store.uploadHTTP(image.data(), image.size() - 1, id, "Image", crc, false, index) == 400);
    assert(store.uploadHTTP(image.data(), image.size(), id, "Image", crc + 1, false, index) == 400);
    assert(store.count() == 0);
    assert(store.uploadHTTP(image.data(), image.size(), id, "HTTP Image", crc, false, index) == 201);
    assert(index == 0 && store.count() == 1);
    assert(store.uploadHTTP(image.data(), image.size(), id, "Retry", crc, false, index) == 200);
    assert(store.count() == 1 && !std::strcmp(store.name(0), "HTTP Image"));
    store.begin(true, "", 1);
    assert(store.uploadHTTP(image.data(), image.size(), id, "Retry after reboot", crc, false, index) == 200);
    image.back() = 1;
    assert(store.uploadHTTP(image.data(), image.size(), id, "Conflict",
        screen_image::checksum(image.data(), image.size()), false, index) == 409);
    image.back() = 0;
    assert(store.uploadHTTP(image.data(), image.size(), other, "Full", crc, false, index) == 507);
    native_device::BLEFrame frame;
    frame.connection = 1;
    frame.length = 45;
    frame.bytes[0] = 0x16;
    for (int byte = 0; byte < 4; ++byte) {
        frame.bytes[1 + byte] = image.size() >> (byte * 8);
        frame.bytes[5 + byte] = crc >> (byte * 8);
    }
    std::memcpy(frame.bytes + 9, id, 36);
    assert(store.consume(frame, false) && reply == 0x11);
    assert(store.uploadHTTP(image.data(), image.size(), id, "Busy", crc, false, index) == 409);
    frame.kind = native_device::FrameKind::data;
    for (size_t offset = 0; offset < image.size(); offset += frame.length) {
        frame.length = std::min(sizeof(frame.bytes), image.size() - offset);
        std::memcpy(frame.bytes, image.data() + offset, frame.length);
        assert(store.consume(frame, false));
    }
    frame.kind = native_device::FrameKind::control;
    frame.length = 1;
    frame.bytes[0] = 0x12;
    assert(store.consume(frame, false) && reply == 0x13);
    assert(store.count() == 1);
    assert(store.removeScreen(0));
    assert(!std::filesystem::exists(directory / "screen-0.pimg.id"));
    const uint8_t button[] = {'P', 'B', 'G', 'I', 1, 0, 2, 0, 2, 0, 0, 85, 170, 255};
    const auto buttonCRC = screen_image::checksum(button, sizeof(button));
    assert(store.uploadHTTP(button, sizeof(button), other, "Button", buttonCRC, true, index) == 201);
    assert(store.uploadHTTP(button, sizeof(button), other, "Retry", buttonCRC, true, index) == 200);
    assert(store.removeHTTP(other, true) == 200);
    assert(store.removeHTTP(other, true) == 404);
    const uint8_t colorButton[] = {'P', 'B', 'G', 'I', 2, 0, 2, 0, 2, 0, 0, 248, 224, 7, 31, 0, 255, 255};
    const auto colorCRC = screen_image::checksum(colorButton, sizeof(colorButton));
    assert(store.uploadHTTP(colorButton, sizeof(colorButton), other, "RGB", colorCRC, true, index) == 201);
    assert(store.buttonImage(other).rgb565);
    assert(store.uploadHTTP(colorButton, sizeof(colorButton), other, "Retry", colorCRC, true, index) == 200);
    assert(store.uploadHTTP(button, sizeof(button), other, "Conflict", buttonCRC, true, index) == 409);
    assert(store.removeHTTP(other, true) == 200);
    native_device::MediaStore missing((directory / "missing").string());
    missing.begin(true);
    assert(missing.uploadHTTP(button, sizeof(button), other, "Button", buttonCRC, true, index) == 500);
    std::filesystem::remove_all(directory);
}