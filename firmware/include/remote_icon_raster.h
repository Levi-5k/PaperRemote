#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>

#include "remote_icon_glyphs.h"

// Allocation-free anti-aliased rasterizer for the generated icon outlines.
namespace remote_icons {

constexpr int32_t kMaxRasterSize = 64;
constexpr int32_t kSubscanlines = 5;
constexpr size_t kMaxCrossings = 48;

inline const Glyph* findGlyph(const char* name) {
    if (name == nullptr || name[0] == '\0') return nullptr;
    for (size_t index = 0; index < kGlyphCount; ++index) {
        if (strcmp(kGlyphs[index].name, name) == 0) return &kGlyphs[index];
    }
    return nullptr;
}

inline void addCoverage(float* coverage, int32_t size, float left, float right, float weight) {
    if (left < 0) left = 0;
    if (right > size) right = static_cast<float>(size);
    if (right <= left) return;
    const int32_t first = static_cast<int32_t>(left);
    const int32_t last = static_cast<int32_t>(right);
    if (first == last) {
        coverage[first] += (right - left) * weight;
        return;
    }
    coverage[first] += (first + 1 - left) * weight;
    for (int32_t x = first + 1; x < last; ++x) coverage[x] += weight;
    if (last < size) coverage[last] += (right - last) * weight;
}

// Calls plot(x, y, coverage) for every touched pixel of a size x size box, coverage 1...255.
// Returns false (after plotting what it could) if a scanline exceeded kMaxCrossings.
template <typename Plot>
bool rasterize(const Glyph& glyph, int32_t size, Plot plot) {
    if (size <= 0 || size > kMaxRasterSize) return false;
    struct Crossing {
        float x;
        int8_t direction;
    };
    const float toPixels = static_cast<float>(size) / kGlyphUnits;
    const float toUnits = static_cast<float>(kGlyphUnits) / size;
    bool complete = true;
    float coverage[kMaxRasterSize];
    Crossing crossings[kMaxCrossings];
    for (int32_t row = 0; row < size; ++row) {
        memset(coverage, 0, sizeof(coverage));
        for (int32_t sample = 0; sample < kSubscanlines; ++sample) {
            const float y = (row + (sample + 0.5f) / kSubscanlines) * toUnits;
            size_t count = 0;
            uint32_t pointIndex = glyph.firstPoint;
            for (uint16_t contour = 0; contour < glyph.contourCount; ++contour) {
                const uint16_t length = kGlyphContourLengths[glyph.firstContour + contour];
                const int16_t* points = &kGlyphPoints[pointIndex * 2];
                pointIndex += length;
                for (uint16_t index = 0; index < length; ++index) {
                    const uint16_t next = index + 1 == length ? 0 : index + 1;
                    const float y0 = points[index * 2 + 1];
                    const float y1 = points[next * 2 + 1];
                    if ((y0 <= y) == (y1 <= y)) continue;
                    if (count == kMaxCrossings) {
                        complete = false;
                        continue;
                    }
                    const float x0 = points[index * 2];
                    const float x1 = points[next * 2];
                    Crossing crossing{
                        (x0 + (y - y0) * (x1 - x0) / (y1 - y0)) * toPixels,
                        static_cast<int8_t>(y1 > y0 ? 1 : -1)};
                    size_t position = count++;
                    while (position > 0 && crossings[position - 1].x > crossing.x) {
                        crossings[position] = crossings[position - 1];
                        --position;
                    }
                    crossings[position] = crossing;
                }
            }
            int32_t winding = 0;
            for (size_t index = 0; index + 1 < count; ++index) {
                winding += crossings[index].direction;
                if (winding != 0) {
                    addCoverage(coverage, size, crossings[index].x, crossings[index + 1].x,
                        1.0f / kSubscanlines);
                }
            }
        }
        for (int32_t x = 0; x < size; ++x) {
            const float value = coverage[x] >= 1.0f ? 255.0f : coverage[x] * 255.0f + 0.5f;
            if (value >= 1.0f) plot(x, row, static_cast<uint8_t>(value));
        }
    }
    return complete;
}

}  // namespace remote_icons
