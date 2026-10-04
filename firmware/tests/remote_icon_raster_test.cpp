#include "remote_icon_raster.h"

#include <cassert>
#include <cmath>
#include <fstream>
#include <iostream>
#include <vector>

namespace {
using namespace remote_icons;

double coveredArea(const Glyph& glyph, int32_t size) {
    double area = 0;
    const bool complete = rasterize(glyph, size, [&](int32_t x, int32_t y, uint8_t value) {
        assert(x >= 0 && x < size && y >= 0 && y < size);
        assert(value > 0);
        area += value / 255.0;
    });
    assert(complete);
    return area;
}

// Writes every glyph at a few sizes as one binary PGM, for visual review.
void writeContactSheet(const char* path) {
    const int32_t sizes[] = {16, 24, 32, 40, 64};
    const int32_t cell = 72;
    const int32_t width = cell * 5;
    const int32_t height = cell * static_cast<int32_t>(kGlyphCount);
    std::vector<uint8_t> pixels(static_cast<size_t>(width) * height, 255);
    for (size_t glyph = 0; glyph < kGlyphCount; ++glyph) {
        for (int32_t column = 0; column < 5; ++column) {
            const int32_t left = column * cell + (cell - sizes[column]) / 2;
            const int32_t top = static_cast<int32_t>(glyph) * cell + (cell - sizes[column]) / 2;
            rasterize(kGlyphs[glyph], sizes[column], [&](int32_t x, int32_t y, uint8_t value) {
                // Quantized to the M5Paper's 16 gray levels.
                pixels[(top + y) * width + left + x] = static_cast<uint8_t>(255 - (value * 15 + 127) / 255 * 17);
            });
        }
    }
    std::ofstream output(path, std::ios::binary);
    output << "P5\n" << width << " " << height << "\n255\n";
    output.write(reinterpret_cast<const char*>(pixels.data()), static_cast<std::streamsize>(pixels.size()));
}
}  // namespace

int main(int argc, char** argv) {
    assert(findGlyph(nullptr) == nullptr);
    assert(findGlyph("") == nullptr);
    assert(findGlyph("square.dashed") == nullptr);
    for (size_t index = 0; index < kGlyphCount; ++index) {
        assert(findGlyph(kGlyphs[index].name) == &kGlyphs[index]);
        for (int32_t size = 1; size <= kMaxRasterSize; ++size) {
            const double area = coveredArea(kGlyphs[index], size);
            assert(area > 0 || size < 4);
            assert(area <= size * size);
        }
    }
    assert(!rasterize(kGlyphs[0], 0, [](int32_t, int32_t, uint8_t) { assert(false); }));
    assert(!rasterize(kGlyphs[0], kMaxRasterSize + 1, [](int32_t, int32_t, uint8_t) { assert(false); }));

    // Phosphor circle-fill is a 208-unit disc; cropped to 240 units it must match pi*r^2.
    const Glyph* circle = findGlyph("circle.fill");
    assert(circle != nullptr);
    for (int32_t size : {12, 24, 40, 64}) {
        const double radius = 104.0 / 240.0 * size;
        const double expected = M_PI * radius * radius;
        assert(std::fabs(coveredArea(*circle, size) - expected) < expected * 0.01 + 1.0);
    }

    // Scaling preserves relative area for every glyph (no dropped or doubled spans).
    for (size_t index = 0; index < kGlyphCount; ++index) {
        const double small = coveredArea(kGlyphs[index], 32) / (32.0 * 32.0);
        const double large = coveredArea(kGlyphs[index], 64) / (64.0 * 64.0);
        assert(std::fabs(small - large) < 0.01);
    }

    if (argc > 1) writeContactSheet(argv[1]);
    std::cout << "remote icon raster tests passed (" << kGlyphCount << " glyphs)\n";
    return 0;
}
