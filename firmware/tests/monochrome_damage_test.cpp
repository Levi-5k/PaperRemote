#include "monochrome_damage.h"
#include "geometric_snake.h"
#include <cassert>
#include <iostream>
#include <vector>

struct Bitmap {
    int width, height, stride;
    std::vector<uint8_t> pixels;
    Bitmap(int w, int h) : width(w), height(h), stride((w + 7) / 8), pixels(stride * h) {}
    void fillScreen(int color) { std::fill(pixels.begin(), pixels.end(), color ? 255 : 0); }
    void drawLine(int x, int y, int endX, int endY, int color) {
        const int dx = std::abs(endX - x), sx = x < endX ? 1 : -1;
        const int dy = -std::abs(endY - y), sy = y < endY ? 1 : -1;
        int error = dx + dy;
        while (true) {
            assert(x >= 0 && x < width && y >= 0 && y < height);
            uint8_t& byte = pixels[y * stride + x / 8];
            const uint8_t mask = 0x80 >> (x % 8);
            if (color) byte |= mask; else byte &= ~mask;
            if (x == endX && y == endY) break;
            const int twice = error * 2;
            if (twice >= dy) { error += dy; x += sx; }
            if (twice <= dx) { error += dx; y += sy; }
        }
    }
};

uint32_t verify(const Bitmap& current, Bitmap& displayed) {
    uint32_t area = 0;
    monochrome_damage::scan(current.pixels.data(), displayed.pixels.data(),
        current.width, current.height, [&](const monochrome_damage::Rect& rect) {
            assert(rect.x >= 0 && rect.y >= 0 && rect.width > 0 && rect.height > 0);
            assert(rect.x + rect.width <= current.width && rect.y + rect.height <= current.height);
            assert(rect.x % 8 == 0 && rect.height <= 16);
            area += rect.width * rect.height;
            for (int y = rect.y; y < rect.y + rect.height; ++y) {
                for (int x = rect.x; x < rect.x + rect.width; ++x) {
                    const int offset = y * current.stride + x / 8;
                    const uint8_t mask = 0x80 >> (x % 8);
                    displayed.pixels[offset] = (displayed.pixels[offset] & ~mask) |
                        (current.pixels[offset] & mask);
                }
            }
        });
    // Compare only visible bits: padding must not trigger or require an update.
    for (int y = 0; y < current.height; ++y) {
        for (int x = 0; x < current.width; ++x) {
            const int offset = y * current.stride + x / 8;
            assert(((current.pixels[offset] ^ displayed.pixels[offset]) & (0x80 >> (x % 8))) == 0);
        }
    }
    return area;
}

int main() {
    for (int width : {1, 7, 8, 9, 31, 32, 33, 540}) {
        Bitmap current(width, 35), displayed(width, 35);
        assert(verify(current, displayed) == 0);
        current.fillScreen(1);
        assert(verify(current, displayed) == static_cast<uint32_t>(width * 35));
        for (int y : {0, 15, 16, 34}) {
            current.drawLine(0, y, 0, y, 0);
            current.drawLine(width - 1, y, width - 1, y, 0);
            assert(verify(current, displayed) > 0);
        }
        assert(verify(current, displayed) == 0);
        if (width % 8) {
            current.pixels.back() ^= 1;
            assert(verify(current, displayed) == 0);
        }
    }
    static geometric_snake::Scene scene;
    Bitmap current(540, 960), displayed(540, 960);
    scene.reset(42, 540, 960);
    uint64_t area = 0;
    for (int frame = 0; frame < 1000; ++frame) {
        geometric_snake::render(current, scene);
        const auto changed = verify(current, displayed);
        if (frame > 0) area += changed;
        scene.advance();
    }
    const double percent = area * 100.0 / (999.0 * 540 * 960);
    assert(percent < 15.0);
    std::cout << "PASS: exact frame reconstruction, boundary/padding checks, 1000 snake frames. "
              << "Average changed-area upload: " << percent << "% of full screen.\n";
}