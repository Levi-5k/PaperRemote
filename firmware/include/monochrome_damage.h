#pragma once

#include <algorithm>
#include <cstdint>

namespace monochrome_damage {

struct Rect { int x; int y; int width; int height; };

// Byte-aligned 1bpp rows, MSB first (M5Canvas layout). Partition the comparison
// into 32x16 tiles, but transfer only each dirty run's tight changed-byte bounds.
// No allocation and no whole-screen bounding box for widely scattered tips.
template <typename Emit>
void scan(const uint8_t* current, const uint8_t* previous,
          int width, int height, Emit emit) {
    const int stride = (width + 7) / 8;
    const int tailBits = width % 8;
    const uint8_t tailMask = tailBits == 0 ? 0xFF : (0xFF << (8 - tailBits));
    for (int band = 0; band < height; band += 16) {
        const int endY = std::min(band + 16, height);
        int runLeft = stride, runRight = -1, runTop = endY, runBottom = -1;
        auto flush = [&]() {
            if (runRight < 0) return;
            emit(Rect{runLeft * 8, runTop,
                std::min(width, (runRight + 1) * 8) - runLeft * 8,
                runBottom - runTop + 1});
            runLeft = stride; runRight = -1; runTop = endY; runBottom = -1;
        };
        for (int tile = 0; tile < stride; tile += 4) {
            int left = stride, right = -1, top = endY, bottom = -1;
            for (int y = band; y < endY; ++y) {
                for (int byte = tile; byte < std::min(tile + 4, stride); ++byte) {
                    const uint8_t mask = byte == stride - 1 ? tailMask : 0xFF;
                    if (((current[y * stride + byte] ^ previous[y * stride + byte]) & mask) == 0) continue;
                    left = std::min(left, byte); right = std::max(right, byte);
                    top = std::min(top, y); bottom = std::max(bottom, y);
                }
            }
            if (right < 0) {
                flush();
            } else {
                runLeft = std::min(runLeft, left); runRight = std::max(runRight, right);
                runTop = std::min(runTop, top); runBottom = std::max(runBottom, bottom);
            }
        }
        flush();
    }
}

}  // namespace monochrome_damage