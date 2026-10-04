#include "remote_text_layout.h"

#include <cassert>
#include <iostream>

// Load the installed LGFX native font DATA without its ESP32 display classes.
// The five data fields match the initializer in each generated font header.
#define PROGMEM
struct GFXglyph {
    uint32_t bitmapOffset;
    uint8_t width, height, xAdvance;
    int8_t xOffset, yOffset;
};
struct GFXfont {
    uint8_t* bitmap;
    GFXglyph* glyph;
    uint16_t first, last;
    uint8_t yAdvance;
};
#include "FreeSansBold9pt7b.h"
#include "FreeSansBold12pt7b.h"
#include "FreeSansBold18pt7b.h"
#include "FreeSansBold24pt7b.h"

int main() {
    using namespace remote_text_layout;
    const GFXfont* fonts[] = {&FreeSansBold9pt7b, &FreeSansBold12pt7b,
                             &FreeSansBold18pt7b, &FreeSansBold24pt7b};
    const char* text = "HOME\ngyp\nPause";
    for (int index = 0; index < 4; ++index) {
        const auto* font = fonts[index];
        assert(font->first == 32 && font->last == 126);
        int above = 0, below = 0;
        for (int code = font->first; code <= font->last; ++code) {
            const auto& glyph = font->glyph[code - font->first];
            above = larger(above, -glyph.yOffset);
            below = larger(below, glyph.yOffset + glyph.height);
        }
        for (int step : {16, 15, 8}) {
            const auto measure = [&](size_t start, size_t bytes) {
                InkMeasure result;
                for (size_t offset = start; offset < start + bytes; ++offset) {
                    const auto& glyph = font->glyph[static_cast<unsigned char>(text[offset]) - font->first];
                    result.add(glyph.xOffset, glyph.yOffset, glyph.width, glyph.height,
                               glyph.xAdvance, step);
                }
                return result.ink;
            };
            Rect area;
            area.x = 12; area.y = 12; area.width = 468; area.height = 296;
            int height = 0, top = -1, bottom = 0, lines = 0;
            const int gap = larger(1, scaled(4, step));
            assert(inkLayout(text, area, larger(1, scaled(above + below, step)), gap,
                1, 1, measure, [&](size_t start, size_t bytes, int pen, int baseline) {
                    const Ink ink = measure(start, bytes);
                    if (!lines++) top = baseline + ink.top;
                    else assert(baseline + ink.top == bottom + gap);
                    bottom = baseline + ink.top + ink.height;
                    assert(std::abs((pen + ink.left - area.x) -
                        (area.x + area.width - pen - ink.left - ink.width)) <= 1);
                    // Every glyph's raster envelope lies inside its ink line.
                    int advance = 0;
                    for (size_t offset = start; offset < start + bytes; ++offset) {
                        const auto& glyph = font->glyph[static_cast<unsigned char>(text[offset]) - font->first];
                        if (scaled(glyph.width, step) &&
                            scaled(glyph.yOffset + glyph.height, step) > scaled(glyph.yOffset, step)) {
                            const int left = pen + advance + scaled(glyph.xOffset, step);
                            assert(left >= area.x && left + scaled(glyph.width, step) <= area.x + area.width);
                            assert(baseline + scaled(glyph.yOffset, step) >= area.y);
                            assert(baseline + scaled(glyph.yOffset + glyph.height, step) <= area.y + area.height);
                        }
                        advance += scaled(glyph.xAdvance, step);
                    }
                }, height, true));
            assert(lines == 3 && bottom - top == height);
            assert(std::abs((top - area.y) - (area.y + area.height - bottom)) <= 1);
            if (step == 16) assert(height < 3 * (above + below + 4));
            area.height = height;
            assert(inkLayout(text, area, larger(1, scaled(above + below, step)), gap,
                1, 1, measure, [](size_t, size_t, int, int) {}, height, false));
            --area.height;
            assert(!inkLayout(text, area, larger(1, scaled(above + below, step)), gap,
                1, 1, measure, [](size_t, size_t, int, int) {}, height, false));
        }
    }

    // Cap selection against actual native glyph sizes in a large and dense
    // title region; no scale >1 and no fractional intermediate native sizes.
    for (int cap : {9, 10, 12, 17, 18, 23, 24}) {
        for (int width : {10, 30, 70, 150, 450}) {
            Rect area;
            area.width = width; area.height = 160;
            const auto choice = chooseFont(cap, [&](int index, int step) {
                assert(step <= 16 && (step == 16 || index == 0));
                const auto* font = fonts[index];
                const auto measure = [&](size_t start, size_t bytes) {
                    InkMeasure result;
                    for (size_t offset = start; offset < start + bytes; ++offset) {
                        const auto& glyph = font->glyph[static_cast<unsigned char>(text[offset]) - font->first];
                        result.add(glyph.xOffset, glyph.yOffset, glyph.width, glyph.height, glyph.xAdvance, step);
                    }
                    return result.ink;
                };
                int height;
                return inkLayout(text, area, larger(1, scaled(font->yAdvance, step)),
                    larger(1, scaled(4, step)), 1, 1, measure,
                    [](size_t, size_t, int, int) {}, height, false);
            });
            assert(choice.index >= 0 && choice.step <= 16);
            const int points[] = {9, 12, 18, 24};
            assert(points[choice.index] <= cap);
            if (width == 450) {
                assert(choice.index == (cap >= 24 ? 3 : cap >= 18 ? 2 : cap >= 12 ? 1 : 0));
                assert(choice.step == 16);
            }
        }
    }
    std::cout << "remote_native_font: real FreeSansBold9/12/18/24 data, centered multiline ink/baselines, exact boundaries and capped selection passed\n";
}