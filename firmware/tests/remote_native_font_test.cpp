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
                        const auto code = titleCodepoint(static_cast<unsigned char>(text[offset]));
                        const auto& glyph = font->glyph[code - font->first];
                        result.add(glyph.xOffset, glyph.yOffset, glyph.width, glyph.height, glyph.xAdvance, step);
                    }
                    return result.ink;
                };
                int height;
                return wordInkLayout(text, area, larger(1, scaled(font->yAdvance, step)),
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
    // Production glyph tables: phrases wrap only at whitespace, whole words
    // shrink the native font, and every emitted line stays inside padded bounds.
    const auto labelInk = [&](const char* label, size_t start, size_t bytes, int index, int step) {
        InkMeasure result;
        const auto* font = fonts[index];
        const size_t length = start + bytes;
        for (size_t offset = start; offset < length;) {
            const size_t next = nextCodepoint(label, offset, length);
            assert(next);
            uint32_t code = next - offset == 1
                ? titleCodepoint(static_cast<unsigned char>(label[offset])) : ' ';
            if (code < font->first || code > font->last) code = ' ';
            const auto& glyph = font->glyph[code - font->first];
            result.add(glyph.xOffset, glyph.yOffset, glyph.width, glyph.height, glyph.xAdvance, step);
            offset = next;
        }
        return result.ink;
    };
    for (const char* label : {"Home All Axes", "Unlock Controller",
        "Very long OpenBuilds motion control button title with multiple words",
        "Home\nAll\rAxes", u8"Déplacement 界😀 gauche",
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789", ""}) {
        for (bool icon : {false, true}) {
            for (bool slider : {false, true}) {
                auto small = buttonLayout(112, 100, icon, slider);
                auto large = buttonLayout(492, 320, icon, slider);
                if (slider) {
                    reserveValue(small.title);
                    reserveValue(large.title);
                }
                FontChoice previous;
                for (const auto& layout : {small, large}) {
                    int height = 0;
                    const auto fits = [&](int index, int step) {
                        return wordInkLayout(label, layout.title, larger(1, scaled(fonts[index]->yAdvance, step)),
                            larger(1, scaled(4, step)), 1, 1,
                            [&](size_t start, size_t bytes) {
                                return labelInk(label, start, bytes, index, step);
                            }, [](size_t, size_t, int, int) {}, height, false);
                    };
                    const auto choice = chooseFont(24, fits);
                    assert(choice.index >= 0 && choice.step <= 16);
                    if (previous.index >= 0) {
                        assert(choice.index >= previous.index);
                        if (choice.index == previous.index) assert(choice.step >= previous.step);
                    }
                    previous = choice;
                    int emitted = 0;
                    assert(wordInkLayout(label, layout.title,
                        larger(1, scaled(fonts[choice.index]->yAdvance, choice.step)),
                        larger(1, scaled(4, choice.step)), 1, 1,
                        [&](size_t start, size_t bytes) {
                            return labelInk(label, start, bytes, choice.index, choice.step);
                        },
                        [&](size_t start, size_t bytes, int pen, int baseline) {
                            assert(start == 0 || space(label[start - 1]) || label[start - 1] == '\n');
                            assert(start + bytes == std::strlen(label) || space(label[start + bytes]) || label[start + bytes] == '\n');
                            const auto ink = labelInk(label, start, bytes, choice.index, choice.step);
                            assert(pen + ink.left >= layout.title.x);
                            assert(pen + ink.left + ink.width <= layout.title.x + layout.title.width);
                            assert(baseline + ink.top >= layout.title.y);
                            assert(baseline + ink.top + ink.height <= layout.title.y + layout.title.height);
                            ++emitted;
                        }, height, true));
                    if (!std::strlen(label)) assert(emitted == 0 && height == 0);
                    else if (!std::strchr(label, ' ') && !std::strchr(label, '\n')) {
                        assert(emitted == 1);
                        assert(height == labelInk(label, 0, std::strlen(label), choice.index, choice.step).height);
                        if (layout.title.width < 112) assert(choice.index == 0 && choice.step < 16);
                    } else assert(emitted > 0);
                    for (int index = choice.index + 1; index < 4; ++index) assert(!fits(index, 16));
                    if (choice.step < 16) {
                        for (int step = choice.step + 1; step <= 16; ++step) assert(!fits(0, step));
                    }
                }
            }
        }
    }
    // Enough height must allow a phrase to stay at 24pt across multiple lines.
    Rect tall;
    tall.width = 150; tall.height = 200;
    int phraseHeight = 0, phraseLines = 0;
    assert(wordInkLayout("Home All Axes", tall, fonts[3]->yAdvance, 4, 1, 1,
        [&](size_t start, size_t bytes) { return labelInk("Home All Axes", start, bytes, 3, 16); },
        [&](size_t, size_t, int, int) { ++phraseLines; }, phraseHeight, true));
    assert(phraseLines > 1);
    std::cout << "remote_native_font: real FreeSansBold9/12/18/24 data, word-only phrases/shrink/resize/UTF-8, native caps, unchanged generic multiline ink passed\n";
}