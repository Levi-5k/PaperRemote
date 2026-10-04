#include "remote_text_layout.h"

#include <cassert>
#include <iostream>
#include <string>
#include <vector>

namespace {
using namespace remote_text_layout;

// Deterministic host font with fractional scaling and a wide UTF-8 glyph.
// Production uses M5.Display's actual metrics through the same algorithm.
int32_t measure(const char* text, size_t start, size_t bytes, int step = 16) {
    int units = 0;
    for (size_t offset = start; offset < start + bytes;) {
        const size_t next = nextCodepoint(text, offset, start + bytes);
        assert(next && next <= start + bytes);
        units += next - offset == 1 ? (text[offset] == ' ' ? 4 : 10) : 18;
        offset = next;
    }
    return (units * step + 15) / 16;
}

bool fits(const char* text, const Rect& area, int step) {
    size_t lines;
    const int lineHeight = (22 * step + 15) / 16 + (4 * step + 15) / 16;
    return wrap(text, area.width, area.height, lineHeight,
        [&](size_t start, size_t bytes) { return measure(text, start, bytes, step); },
        [](size_t, size_t, int32_t, size_t) {}, lines);
}

void inside(const Rect& inner, const Rect& outer) {
    assert(inner.width >= 0 && inner.height >= 0);
    assert(inner.x >= outer.x && inner.y >= outer.y);
    assert(inner.x + inner.width <= outer.x + outer.width);
    assert(inner.y + inner.height <= outer.y + outer.height);
}

std::vector<std::string> linesFor(const char* text, int width, int height, bool expected = true) {
    std::vector<std::string> result;
    size_t count;
    const bool success = wrap(text, width, height, 26,
        [&](size_t start, size_t bytes) { return measure(text, start, bytes); },
        [&](size_t start, size_t bytes, int32_t lineWidth, size_t line) {
            assert(lineWidth <= width && (line + 1) * 26 <= static_cast<size_t>(height));
            result.emplace_back(text + start, bytes);
        }, count);
    assert(success == expected);
    return result;
}
}

int main() {
    using namespace remote_text_layout;
    assert((linesFor("one two three", 70, 78) == std::vector<std::string>{"one two", "three"}));
    assert((linesFor("ABCDEFGHI", 30, 78) == std::vector<std::string>{"ABC", "DEF", "GHI"}));
    assert((linesFor("one   two", 60, 52) == std::vector<std::string>{"one", "two"}));
    assert((linesFor("  one  \n\n two \n", 40, 78) == std::vector<std::string>{"one", "", "two"}));
    assert((linesFor(u8"é界😀é", 36, 52) == std::vector<std::string>{u8"é界", u8"😀é"}));
    assert((linesFor(u8"go 界😀", 36, 52) == std::vector<std::string>{"go", u8"界😀"}));
    linesFor("W", 9, 26, false); // Wide first glyph must fail, not overflow.
    linesFor(u8"界", 17, 26, false);
    linesFor("ABC", 10, 52, false); // Height, not just width, bounds wrapping.
    linesFor("A", 10, 25, false);
    linesFor("A", 0, 26, false);
    linesFor("\xC3", 100, 26, false); // Truncated stored UTF-8 label.
    linesFor("\xED\xA0\x80", 100, 26, false); // Invalid surrogate.
    linesFor("\xF4\x90\x80\x80", 100, 26, false);
    const std::string newlines(1000, '\n');
    assert(linesFor(newlines.c_str(), 10, 26000).size() == 1000);
    linesFor(newlines.c_str(), 10, 26, false); // No bounded line array to overrun.

    const char* labels[] = {"Home All Axes", "Unlock Controller", "Pause", "",
        "Very long OpenBuilds motion control button title with multiple words",
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789", u8"Déplacement 界😀 gauche"};
    const int frames[][2] = {{29, 32}, {42, 44}, {55, 50}, {70, 76}, {112, 60},
        {152, 132}, {234, 164}, {492, 50}, {492, 320}, {20, 20}};
    for (const auto& frame : frames) {
        for (bool hasIcon : {false, true}) {
            const auto layout = buttonLayout(frame[0], frame[1], hasIcon);
            Rect frameArea;
            frameArea.width = frame[0]; frameArea.height = frame[1];
            inside(layout.content, frameArea);
            inside(layout.title, layout.content);
            if (layout.iconSize) {
                Rect icon;
                icon.x = layout.iconX - layout.iconSize / 2 - 4;
                icon.y = layout.iconY - layout.iconSize / 2 - 4;
                icon.width = icon.height = layout.iconSize + 8;
                inside(icon, layout.content);
                assert(layout.horizontal ? icon.x + icon.width <= layout.title.x
                    : icon.y + icon.height <= layout.title.y);
            }
            for (const char* label : labels) {
                const int chosen = largestFit(16, [&](int step) { return fits(label, layout.title, step); });
                assert(chosen > 0 && fits(label, layout.title, chosen));
                for (int step = chosen + 1; step <= 16; ++step) assert(!fits(label, layout.title, step));
            }
            const auto slider = buttonLayout(frame[0], frame[1], hasIcon, true);
            auto title = slider.title;
            const auto value = reserveValue(title);
            inside(title, slider.title); inside(value, slider.title);
            assert(title.x + title.width <= value.x);
            for (const char* text : {"72 F", "22 C", "100%"}) {
                const int chosen = largestFit(16, [&](int step) { return fits(text, value, step); });
                assert(chosen > 0);
            }
        }
    }
    // Recompute on resize: orientation, icon and largest fitting type change.
    const auto small = buttonLayout(42, 44, true);
    const auto large = buttonLayout(234, 164, true);
    assert(small.iconSize > 0 && large.iconSize > small.iconSize);
    assert(buttonLayout(29, 32, true).iconSize > 0);
    assert(buttonLayout(20, 20, true).iconSize == 0);
    assert(buttonLayout(234, 50, true).horizontal && !large.horizontal);
    const char* label = "Home All Axes";
    const auto choose = [&](const Rect& area) {
        return largestFit(16, [&](int step) { return fits(label, area, step); });
    };
    assert(choose(large.title) > choose(small.title));
    assert(choose(small.title) == choose(buttonLayout(42, 44, true).title));
    assert(buttonLayout(0, 50, true).content.width == 0);
    assert(buttonLayout(50, 1, true).content.height == 0);
    assert(largestFit(42, [](int) { return false; }) == 0);
    // Non-monotonic metrics still choose the actual largest fit.
    assert(largestFit(42, [](int step) { return step == 17 || step == 29; }) == 29);
    // Exhaustive tiny-to-large geometry: symmetric title, padded icon halo,
    // and compact vertical groups rather than oversized text allocations.
    for (int width = 3; width <= 540; ++width) {
        for (int height = 3; height <= 400; ++height) {
            auto layout = buttonLayout(width, height, true);
            Rect frame;
            frame.width = width; frame.height = height;
            inside(layout.content, frame);
            inside(layout.title, layout.content);
            if (layout.horizontal) assert(layout.title.x * 2 + layout.title.width == width);
            if (!layout.iconSize) continue;
            for (int textHeight : {0, 1, layout.title.height / 2, layout.title.height}) {
                auto compact = layout;
                centerVerticalGroup(compact, textHeight);
                Rect halo;
                halo.x = compact.iconX - (compact.iconSize + 8) / 2;
                halo.y = compact.iconY - (compact.iconSize + 8) / 2;
                halo.width = halo.height = compact.iconSize + 8;
                inside(halo, compact.content);
                inside(compact.title, compact.content);
                if (compact.horizontal) assert(halo.x + halo.width + compact.gap <= compact.title.x);
                else {
                    assert(halo.y + halo.height + (textHeight ? compact.gap : 0) == compact.title.y);
                    assert(compact.title.height == textHeight);
                    const int groupBottom = textHeight ? compact.title.y + textHeight : halo.y + halo.height;
                    assert(std::abs((halo.y - compact.content.y) -
                        (compact.content.y + compact.content.height - groupBottom)) <= 1);
                }
            }
        }
    }

    for (int cap = -5; cap <= 30; ++cap) {
        const int points[] = {9, 12, 18, 24};
        const auto choice = chooseFont(cap, [&](int index, int step) {
            assert(step <= 16 && step > 0);
            assert(points[index] <= clampMaxButtonTextSize(cap));
            assert(step == 16 || index == 0);
            return true;
        });
        assert(choice.step == 16);
        const int expected = cap >= 24 ? 3 : cap >= 18 ? 2 : cap >= 12 ? 1 : 0;
        assert(choice.index == expected);
    }
    assert(chooseFont(24, [](int index, int step) { return index <= 2 && step == 16; }).index == 2);
    assert(chooseFont(24, [](int index, int step) { return index <= 1 && step == 16; }).index == 1);
    assert(chooseFont(24, [](int index, int step) { return index == 0 && step <= 7; }).step == 7);
    assert(chooseFont(24, [](int, int) { return false; }).index == -1);
    assert(clampMaxButtonTextSize(0) == 9 && clampMaxButtonTextSize(255) == 24);

    // Different visible line heights and bearings, including negative offsets
    // and descenders. Origins must land the INK, not the advance/font envelope.
    const char* multiline = "ABC\ngyp\nI";
    const auto inkFor = [&](size_t start, size_t bytes) {
        Ink ink;
        ink.left = start == 0 ? -2 : 2;
        ink.top = start == 4 ? -8 : -12;
        ink.width = static_cast<int32_t>(bytes) * 10;
        ink.height = start == 4 ? 13 : 12;
        return ink;
    };
    Rect area;
    area.x = 7; area.y = 11; area.width = 80; area.height = 81;
    for (uint8_t horizontal : {0, 1, 2}) {
        for (uint8_t vertical : {0, 1, 2}) {
            int blockHeight = 0, firstTop = -1, lastBottom = 0;
            int emitted = 0;
            assert(inkLayout(multiline, area, 25, 4, horizontal, vertical, inkFor,
                [&](size_t start, size_t bytes, int penX, int baseline) {
                    const auto ink = inkFor(start, bytes);
                    Rect visible;
                    visible.x = penX + ink.left; visible.y = baseline + ink.top;
                    visible.width = ink.width; visible.height = ink.height;
                    inside(visible, area);
                    assert(visible.x == area.x + alignedOffset(area.width, ink.width, horizontal));
                    if (!emitted++) firstTop = visible.y;
                    else assert(visible.y == lastBottom + 4);
                    lastBottom = visible.y + ink.height;
                }, blockHeight, true));
            assert(emitted == 3 && blockHeight == 45 && lastBottom - firstTop == 45);
            assert(firstTop == area.y + alignedOffset(area.height, 45, vertical));
        }
    }
    int blockHeight = 0;
    area.height = 45;
    assert(inkLayout(multiline, area, 25, 4, 1, 1, inkFor,
        [](size_t, size_t, int, int) {}, blockHeight, false));
    area.height = 44;
    assert(!inkLayout(multiline, area, 25, 4, 1, 1, inkFor,
        [](size_t, size_t, int, int) { assert(false); }, blockHeight, true));
    area.height = 80; area.width = 29;
    // Word/character wrap still uses measured ink bounds, not advances.
    assert(inkLayout("ABC", area, 25, 4, 1, 1, inkFor,
        [](size_t, size_t, int, int) {}, blockHeight, false));
    area.width = 9;
    assert(!inkLayout("A", area, 25, 4, 1, 1, inkFor,
        [](size_t, size_t, int, int) {}, blockHeight, false));
    area.width = 80;
    assert(inkLayout("", area, 25, 4, 1, 1, inkFor,
        [](size_t, size_t, int, int) { assert(false); }, blockHeight, true) && blockHeight == 0);
    assert(!inkLayout("\xC3", area, 25, 4, 1, 1, inkFor,
        [](size_t, size_t, int, int) {}, blockHeight, false));

    InkMeasure glyphs;
    glyphs.add(-2, -12, 10, 12, 11, 16);
    glyphs.add(1, -8, 9, 13, 10, 16);
    assert(glyphs.ink.left == -2 && glyphs.ink.top == -12);
    assert(glyphs.ink.width == 23 && glyphs.ink.height == 17 && glyphs.advance == 21);
    assert(scaled(-3, 8) == -2 && scaled(3, 8) == 1);
    InkMeasure shrunk;
    shrunk.add(-3, -11, 10, 14, 12, 8);
    assert(shrunk.ink.left == -2 && shrunk.ink.top == -6);
    assert(shrunk.ink.width == 5 && shrunk.ink.height == 7 && shrunk.advance == 6);
    std::cout << "remote_text_layout: wrapping/UTF-8, 214124 geometries, centered ink/multiline groups, bearings/boundaries, native fonts/caps/shrink passed\n";
}