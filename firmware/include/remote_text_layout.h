#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>

// Allocation-free, display-independent layout. All state is per draw (no BSS).
namespace remote_text_layout {

inline int32_t smaller(int32_t a, int32_t b) { return a < b ? a : b; }
inline int32_t larger(int32_t a, int32_t b) { return a > b ? a : b; }

struct Rect {
    int32_t x = 0, y = 0, width = 0, height = 0;
};

struct ButtonLayout {
    Rect content;
    Rect title;
    int32_t iconX = 0, iconY = 0, iconSize = 0;
    int32_t gap = 0;
    bool horizontal = false;
};

inline ButtonLayout buttonLayout(int32_t width, int32_t height, bool hasIcon,
                                bool forceHorizontal = false) {
    ButtonLayout result;
    if (width <= 2 || height <= 2) return result;
    const int32_t padding = smaller(12, larger(1, smaller(width, height) / 6));
    result.content.x = result.content.y = padding;
    result.content.width = width - padding * 2;
    result.content.height = height - padding * 2;
    result.title = result.content;
    result.horizontal = forceHorizontal || height <= width * 2 / 3;
    if (!hasIcon) return result;
    const int32_t gap = smaller(8, larger(1, smaller(width, height) / 10));
    const int32_t extent = result.horizontal
        ? smaller(40, smaller(result.content.height,
            smaller(larger(16, result.content.width / 4),
                (result.content.width - larger(8, result.content.width / 3)) / 2 - gap)))
        : smaller(48, smaller(result.content.width,
            smaller(larger(16, result.content.height / 3), result.content.height * 2 / 3)));
    // Legacy vector symbols can extend 3px beyond their nominal size.
    // Reserve a 4px halo, rather than relying on clipping to make them fit.
    if (extent < 16) return result;
    result.iconSize = extent - 8;
    result.gap = gap;
    if (result.horizontal) {
        result.iconX = padding + extent / 2;
        result.iconY = height / 2;
        result.title.x += extent + gap;
        // Reserve the same space on BOTH sides: title center == button center.
        result.title.width -= (extent + gap) * 2;
    } else {
        result.iconX = width / 2;
        result.iconY = padding + extent / 2;
        result.title.y += extent + gap;
        result.title.height -= extent + gap;
    }
    return result;
}

inline void centerVerticalGroup(ButtonLayout& layout, int32_t textHeight) {
    if (layout.horizontal || !layout.iconSize) return;
    const int32_t extent = layout.iconSize + 8;
    textHeight = smaller(layout.title.height, larger(0, textHeight));
    const int32_t gap = textHeight ? layout.gap : 0;
    const int32_t top = layout.content.y +
        (layout.content.height - extent - gap - textHeight) / 2;
    layout.iconY = top + extent / 2;
    layout.title.y = top + extent + gap;
    layout.title.height = textHeight;
}

inline uint8_t clampMaxButtonTextSize(int nominalPoints) {
    return static_cast<uint8_t>(smaller(24, larger(9, nominalPoints)));
}

struct FontChoice {
    int index = -1;
    int step = 16; // sixteenths; native glyphs are always drawn at 16/16.
};

template <typename Fits>
FontChoice chooseFont(int maximumPoints, Fits fits) {
    const int points[] = {9, 12, 18, 24};
    FontChoice choice;
    maximumPoints = clampMaxButtonTextSize(maximumPoints);
    for (int index = 3; index >= 0; --index) {
        if (points[index] <= maximumPoints && fits(index, 16)) {
            choice.index = index;
            return choice;
        }
    }
    for (int step = 15; step > 0; --step) {
        if (fits(0, step)) {
            choice.index = 0;
            choice.step = step;
            return choice;
        }
    }
    return choice;
}

struct Ink {
    int32_t left = 0, top = 0, width = 0, height = 0;
};

// Match LGFX's fixed-point floor (including negative glyph bearings).
inline int32_t scaled(int32_t pixels, int step) {
    const int32_t value = pixels * step;
    return value >= 0 ? value / 16 : -((-value + 15) / 16);
}

struct InkMeasure {
    Ink ink;
    int32_t advance = 0;
    bool visible = false;

    void add(int32_t xOffset, int32_t yOffset, int32_t width, int32_t height,
             int32_t xAdvance, int step) {
        const int32_t left = advance + scaled(xOffset, step);
        const int32_t top = scaled(yOffset, step);
        const int32_t right = left + scaled(width, step);
        const int32_t bottom = scaled(yOffset + height, step);
        if (right > left && bottom > top) {
            const int32_t oldRight = ink.left + ink.width, oldBottom = ink.top + ink.height;
            ink.left = visible ? smaller(ink.left, left) : left;
            ink.top = visible ? smaller(ink.top, top) : top;
            ink.width = (visible ? larger(oldRight, right) : right) - ink.left;
            ink.height = (visible ? larger(oldBottom, bottom) : bottom) - ink.top;
            visible = true;
        }
        advance += scaled(xAdvance, step);
    }
};

inline int32_t alignedOffset(int32_t available, int32_t used, uint8_t alignment) {
    return alignment == 1 ? (available - used) / 2 : alignment == 2 ? available - used : 0;
}

inline Rect reserveValue(Rect& title) {
    Rect value = title;
    const int32_t gap = title.width > 6 ? 2 : 0;
    value.width = title.width / 3;
    value.x += title.width - value.width;
    title.width -= value.width + gap;
    return value;
}

// Reject malformed/truncated UTF-8 rather than sending partial glyphs to the
// display. Returns the next complete codepoint boundary, or zero on failure.
inline size_t nextCodepoint(const char* text, size_t offset, size_t length) {
    const uint8_t first = static_cast<uint8_t>(text[offset]);
    const size_t bytes = first < 0x80 ? 1 : first >= 0xC2 && first <= 0xDF ? 2
        : first >= 0xE0 && first <= 0xEF ? 3 : first >= 0xF0 && first <= 0xF4 ? 4 : 0;
    if (!bytes || bytes > length - offset) return 0;
    for (size_t index = 1; index < bytes; ++index) {
        const uint8_t byte = static_cast<uint8_t>(text[offset + index]);
        if ((byte & 0xC0) != 0x80) return 0;
    }
    if (bytes >= 3) {
        const uint8_t second = static_cast<uint8_t>(text[offset + 1]);
        if ((first == 0xE0 && second < 0xA0) || (first == 0xED && second >= 0xA0) ||
            (first == 0xF0 && second < 0x90) || (first == 0xF4 && second >= 0x90)) return 0;
    }
    return offset + bytes;
}

inline bool space(char c) { return c == ' ' || c == '\t' || c == '\r'; }

// measure(start, byteCount) must measure the complete span, including glyph
// bearings. emit(start, byteCount, width, lineIndex) receives whole UTF-8 spans.
// No line-width array: even thousands of newlines cannot overrun local storage.
template <typename Measure, typename Emit>
bool wrap(const char* text, int32_t width, int32_t height, int32_t lineHeight,
          Measure measure, Emit emit, size_t& lineCount) {
    lineCount = 0;
    if (!text || width <= 0 || height <= 0 || lineHeight <= 0 || lineHeight > height) return false;
    const size_t length = std::strlen(text);
    size_t position = 0;
    while (position < length) {
        while (position < length && space(text[position])) ++position;
        if (position == length) break;
        const size_t start = position;
        size_t end = start, breakAt = start, resumeAt = start;
        while (position < length && text[position] != '\n') {
            if (space(text[position])) {
                breakAt = end;
                do { ++position; } while (position < length && space(text[position]));
                resumeAt = position;
                continue;
            }
            const size_t next = nextCodepoint(text, position, length);
            if (!next) return false;
            const int32_t candidateWidth = measure(start, next - start);
            if (candidateWidth < 0) return false;
            if (candidateWidth > width) {
                if (end == start) return false; // A single glyph is too wide.
                if (breakAt > start) { end = breakAt; position = resumeAt; }
                break;
            }
            end = next;
            position = next;
        }
        if (lineCount >= static_cast<size_t>(height / lineHeight)) return false;
        const int32_t lineWidth = end == start ? 0 : measure(start, end - start);
        if (lineWidth < 0 || lineWidth > width) return false;
        emit(start, end - start, lineWidth, lineCount++);
        if (position < length && text[position] == '\n') ++position;
    }
    return true;
}

// Measure and center each line's visible ink, not a font-wide envelope. Blank
// lines keep their nominal height; no trailing interline gap enters the block.
// emit receives the pen X and baseline Y relative to the supplied area.
template <typename Measure, typename Emit>
bool inkLayout(const char* text, const Rect& area, int32_t blankHeight, int32_t gap,
               uint8_t horizontalAlignment, uint8_t verticalAlignment,
               Measure measure, Emit emit, int32_t& textHeight, bool draw) {
    textHeight = 0;
    size_t count = 0;
    const auto width = [&](size_t start, size_t bytes) { return measure(start, bytes).width; };
    if (!wrap(text, area.width, INT32_MAX, 1, width,
        [&](size_t start, size_t bytes, int32_t, size_t line) {
            const Ink ink = measure(start, bytes);
            textHeight += (line ? gap : 0) + (ink.height ? ink.height : blankHeight);
        }, count) || area.height <= 0 || textHeight > area.height) return false;
    if (!draw) return true;
    int32_t top = area.y + alignedOffset(area.height, textHeight, verticalAlignment);
    return wrap(text, area.width, INT32_MAX, 1, width,
        [&](size_t start, size_t bytes, int32_t lineWidth, size_t) {
            const Ink ink = measure(start, bytes);
            emit(start, bytes,
                area.x + alignedOffset(area.width, lineWidth, horizontalAlignment) - ink.left,
                top - ink.top);
            top += (ink.height ? ink.height : blankHeight) + gap;
        }, count);
}

// Search every size, not binary search: font rounding/wrapping can change at
// different thresholds. Returns the largest tested size fitting BOTH axes.
template <typename Fits>
int largestFit(int maximum, Fits fits) {
    for (int step = maximum; step > 0; --step) {
        if (fits(step)) return step;
    }
    return 0;
}

} // namespace remote_text_layout