#include "screen_image.h"
#include "media_store.h"
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <vector>
#include <unistd.h>

static int64_t clockMicros = 0;
static uint8_t lastReply = 0;
static uint32_t lastAck = 0;
extern "C" int64_t esp_timer_get_time() { return clockMicros; }
void* heap_caps_malloc(size_t size, uint32_t) { return std::malloc(size); }
void heap_caps_free(void* pointer) { std::free(pointer); }
bool native_device::notify(uint16_t, const uint8_t* bytes, size_t length) {
    lastReply = bytes[0];
    if (length == 5) lastAck = uint32_t(bytes[1]) | uint32_t(bytes[2]) << 8 |
        uint32_t(bytes[3]) << 16 | uint32_t(bytes[4]) << 24;
    return true;
}

static void transfer(native_device::MediaStore& store, const std::vector<uint8_t>& data,
                     bool badCRC = false, const char* id = nullptr) {
    native_device::BLEFrame frame;
    frame.connection = 7;
    frame.length = id ? 45 : 9;
    frame.bytes[0] = id ? 0x46 : 0x10;
    const uint32_t crc = screen_image::checksum(data.data(), data.size()) ^ uint32_t(badCRC);
    for (int index = 0; index < 4; ++index) {
        frame.bytes[1 + index] = uint8_t(data.size() >> (index * 8));
        frame.bytes[5 + index] = uint8_t(crc >> (index * 8));
    }
    if (id) std::memcpy(frame.bytes + 9, id, 36);
    assert(store.consume(frame, false) && store.busy());
    assert(lastReply == (id ? 0x41 : 0x11));
    frame.connection = 8;
    store.consume(frame, false);
    assert(lastReply == 0x7f && store.busy());
    frame.connection = 7;
    frame.kind = native_device::FrameKind::data;
    for (size_t offset = 0; offset < data.size(); offset += frame.length) {
        frame.length = std::min<size_t>(512, data.size() - offset);
        std::memcpy(frame.bytes, data.data() + offset, frame.length);
        assert(store.consume(frame, false));
    }
    assert(lastAck == data.size() && lastReply == (id ? 0x44 : 0x14));
    frame.kind = native_device::FrameKind::control;
    frame.length = 1;
    frame.bytes[0] = id ? 0x47 : 0x12;
    assert(store.consume(frame, false) && !store.busy());
    assert(lastReply == (badCRC ? 0x7f : id ? 0x48 : 0x13));
}

int main() {
    uint8_t image[] = {'P','I','M','G',1,0,2,0,1,0,0,0xf8,0x1f,0};
    assert(screen_image::valid(image, sizeof(image), 2, 1));
    assert(!screen_image::valid(image, sizeof(image) - 1, 2, 1));
    assert(!screen_image::valid(image, sizeof(image), 1, 2));
    image[4] = 2;
    assert(!screen_image::valid(image, sizeof(image), 2, 1));
    assert(!screen_image::valid(nullptr, sizeof(image), 2, 1));
    assert(screen_image::checksum(reinterpret_cast<const uint8_t*>("123456789"), 9) == 0xcbf43926);
    char directory[] = "/tmp/papergif-images-XXXXXX";
    assert(mkdtemp(directory));
    std::ofstream(std::string(directory) + "/remote.json") << "preserve profile";
    std::vector<uint8_t> screen(10 + 368 * 448 * 2, 0);
    const uint8_t header[] = {'P','I','M','G',1,0,0x70,1,0xc0,1};
    std::memcpy(screen.data(), header, sizeof(header));
    screen[10] = 0xe0; screen[11] = 7;
    {
        native_device::MediaStore store(directory);
        store.begin(true);
        transfer(store, screen);
        assert(store.count() == 1 && store.screen(0)[0] == 0xe0);
        transfer(store, screen, true);
        assert(store.count() == 1);
        native_device::BLEFrame begin;
        begin.connection = 7;
        begin.length = 9;
        begin.bytes[0] = 0x10;
        begin.bytes[1] = 10;
        store.consume(begin, true);
        assert(!store.busy() && lastReply == 0x7f);
        store.consume(begin, false);
        assert(store.busy());
        clockMicros = 31000000;
        store.poll(31000);
        assert(!store.busy() && lastReply == 0x7f && store.count() == 1);
        store.consume(begin, false);
        begin.kind = native_device::FrameKind::disconnected;
        store.consume(begin, false);
        assert(!store.busy());
        const std::vector<uint8_t> button = {'P','B','G','I',1,0,2,0,2,0,0,85,170,255};
        transfer(store, button, false, "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee");
        const auto decoded = store.buttonImage("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE");
        assert(decoded.width == 2 && decoded.height == 2 && decoded.pixels[3] == 255);
        assert(!store.buttonImage("../../remote.json").pixels);
    }
    {
        native_device::MediaStore restarted(directory);
        restarted.begin(true);
        assert(restarted.count() == 1 && restarted.screen(0)[0] == 0xe0);
        restarted.clearScreens();
        assert(restarted.count() == 0);
        assert(std::filesystem::exists(std::string(directory) + "/remote.json"));
    }
    {
        native_device::MediaStore card(directory);
        card.begin(true, directory, 128);
        for (size_t index = 0; index < 8; ++index) {
            screen[10] = uint8_t(index);
            transfer(card, screen);
        }
        assert(card.count() == 8 && card.capacity() == 128);
        for (size_t index = 0; index < 8; ++index) assert(card.screen(index)[0] == index);
        native_device::BLEFrame request;
        request.connection = 7;
        request.length = 1;
        request.bytes[0] = 0x20;
        assert(card.library(request, 2) && lastReply == 0x21);
        request.length = 2;
        request.bytes[0] = 0x22;
        request.bytes[1] = 2;
        assert(card.library(request, 2) && lastReply == 0x22);
        request.bytes[0] = 0x23;
        assert(card.library(request, 2) && lastReply == 0x24 && card.count() == 7);
        assert(card.screen(2)[0] == 3);
        card.begin(true, directory, 128);
        assert(card.count() == 7 && card.screen(6)[0] == 7);
        card.clearScreens();
        assert(card.count() == 0 && std::filesystem::exists(std::string(directory) + "/remote.json"));
    }
    std::filesystem::remove_all(directory);
    std::puts("Image wire format, CRC, ownership, timeout, disconnect, persistence and button assets passed");
}