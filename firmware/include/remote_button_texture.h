#pragma once

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>

// Button textures: geometric patterns or converted images drawn behind idle buttons.
// Image quantization mirrors the iPhone app's PaperGIFEncoder conversion modes.
namespace remote_button_texture {

enum class Kind : uint8_t { none = 0, pattern = 1, image = 2 };

enum class Pattern : uint8_t {
    hexagons = 0,
    triangles,
    grid,
    dots,
    diagonal,
    checker,
    waves,
    rings,
    spiral,
    truchet,
};

enum class Mode : uint8_t { threshold = 0, monochrome, halftone, combined };

constexpr size_t kImageIdBytes = 37;
constexpr uint16_t kMaximumImageSide = 540;
constexpr size_t kImageHeaderBytes = 10;

struct Texture {
    Kind kind = Kind::none;
    Pattern pattern = Pattern::hexagons;
    uint8_t scale = 16;
    uint8_t lineWidth = 1;
    Mode mode = Mode::monochrome;
    uint8_t threshold = 128;
    uint8_t levels = 16;
    uint8_t dotSpacing = 8;
    uint8_t angle = 45;
    int8_t dotGain = 0;
    uint8_t fade = 50;
    char imageId[kImageIdBytes] = {};

    bool operator==(const Texture& other) const {
        return kind == other.kind && pattern == other.pattern && scale == other.scale &&
            lineWidth == other.lineWidth && mode == other.mode &&
            threshold == other.threshold && levels == other.levels &&
            dotSpacing == other.dotSpacing && angle == other.angle &&
            dotGain == other.dotGain && fade == other.fade &&
            strcmp(imageId, other.imageId) == 0;
    }
    bool operator!=(const Texture& other) const { return !(*this == other); }
};

inline bool parseKind(const char* name, Kind& result) {
    static const char* const names[] = {"none", "pattern", "image"};
    for (uint8_t index = 0; name != nullptr && index < 3; ++index) {
        if (strcmp(name, names[index]) == 0) {
            result = static_cast<Kind>(index);
            return true;
        }
    }
    return false;
}

inline bool parsePattern(const char* name, Pattern& result) {
    static const char* const names[] = {
        "hexagons", "triangles", "grid", "dots", "diagonal",
        "checker", "waves", "rings", "spiral", "truchet",
    };
    for (uint8_t index = 0; name != nullptr && index < 10; ++index) {
        if (strcmp(name, names[index]) == 0) {
            result = static_cast<Pattern>(index);
            return true;
        }
    }
    return false;
}

inline bool parseMode(const char* name, Mode& result) {
    static const char* const names[] = {"threshold", "monochrome", "halftone", "combined"};
    for (uint8_t index = 0; name != nullptr && index < 4; ++index) {
        if (strcmp(name, names[index]) == 0) {
            result = static_cast<Mode>(index);
            return true;
        }
    }
    return false;
}

// Accepts only canonical UUID text, so the ID is safe to use in an SD path.
inline bool normalizeImageId(const char* input, char output[kImageIdBytes]) {
    if (input == nullptr || strlen(input) != kImageIdBytes - 1) return false;
    for (size_t index = 0; index < kImageIdBytes - 1; ++index) {
        char character = input[index];
        const bool dash = index == 8 || index == 13 || index == 18 || index == 23;
        if (dash) {
            if (character != '-') return false;
        } else if (character >= 'a' && character <= 'f') {
            character = static_cast<char>(character - 'a' + 'A');
        } else if (!((character >= '0' && character <= '9') ||
                     (character >= 'A' && character <= 'F'))) {
            return false;
        }
        output[index] = character;
    }
    output[kImageIdBytes - 1] = '\0';
    return true;
}

// "PBGI", version 1, reserved, width/height (LE), then 8-bit luminance rows.
inline bool parseImageHeader(const uint8_t* header, uint32_t fileBytes,
                             uint16_t& width, uint16_t& height) {
    if (fileBytes < kImageHeaderBytes || memcmp(header, "PBGI", 4) != 0 || header[4] != 1) {
        return false;
    }
    width = static_cast<uint16_t>(header[6] | header[7] << 8);
    height = static_cast<uint16_t>(header[8] | header[9] << 8);
    return width > 0 && height > 0 && width <= kMaximumImageSide &&
        height <= kMaximumImageSide &&
        fileBytes == kImageHeaderBytes + static_cast<uint32_t>(width) * height;
}

inline float clampUnit(float value) { return value < 0 ? 0 : value > 1 ? 1 : value; }

inline float nearestMultipleDistance(float value, float spacing) {
    return fabsf(value - spacing * roundf(value / spacing));
}

inline float positiveModulo(float value, float divisor) {
    return value - divisor * floorf(value / divisor);
}

// Same integer hash as the iPhone preview, so Truchet tiles match.
inline bool truchetFlip(int32_t column, int32_t row) {
    uint32_t hash = static_cast<uint32_t>(column) * 0x9E3779B1u ^
        static_cast<uint32_t>(row) * 0x85EBCA77u;
    hash ^= hash >> 15;
    hash *= 0x2C1B3C6Du;
    hash ^= hash >> 12;
    return (hash & 1u) != 0;
}

// Ink coverage (0..1) at a pixel center, in coordinates relative to the button center.
inline float patternCoverage(Pattern pattern, float x, float y, float spacing, float lineWidth) {
    const float halfLine = lineWidth * 0.5f;
    const auto line = [&](float distance) { return clampUnit(halfLine + 0.5f - distance); };
    switch (pattern) {
    case Pattern::hexagons: {
        const float px = x / spacing;
        const float py = y / spacing;
        const float rowStep = 1.7320508f;
        const float ax = positiveModulo(px, 1.0f) - 0.5f;
        const float ay = positiveModulo(py, rowStep) - rowStep * 0.5f;
        const float bx = positiveModulo(px - 0.5f, 1.0f) - 0.5f;
        const float by = positiveModulo(py - rowStep * 0.5f, rowStep) - rowStep * 0.5f;
        const bool useA = ax * ax + ay * ay < bx * bx + by * by;
        const float gx = fabsf(useA ? ax : bx);
        const float gy = fabsf(useA ? ay : by);
        const float hexDistance = fmaxf(gx * 0.5f + gy * 0.8660254f, gx);
        return line(fabsf(0.5f - hexDistance) * spacing);
    }
    case Pattern::triangles: {
        const float height = spacing * 0.8660254f;
        const float d0 = nearestMultipleDistance(y, height);
        const float d1 = nearestMultipleDistance(x * 0.8660254f + y * 0.5f, height);
        const float d2 = nearestMultipleDistance(x * 0.8660254f - y * 0.5f, height);
        return line(fminf(d0, fminf(d1, d2)));
    }
    case Pattern::grid:
        return line(fminf(nearestMultipleDistance(x, spacing), nearestMultipleDistance(y, spacing)));
    case Pattern::dots: {
        const float dx = x - spacing * roundf(x / spacing);
        const float dy = y - spacing * roundf(y / spacing);
        const float radius = fmaxf(1.0f, spacing * 0.15f + halfLine);
        return clampUnit(radius + 0.5f - sqrtf(dx * dx + dy * dy));
    }
    case Pattern::diagonal:
        return line(nearestMultipleDistance((x + y) * 0.70710678f, spacing));
    case Pattern::checker: {
        const float cx = positiveModulo(x, spacing);
        const float cy = positiveModulo(y, spacing);
        const float edge = fminf(fminf(cx, spacing - cx), fminf(cy, spacing - cy));
        const bool inside = ((static_cast<int32_t>(floorf(x / spacing)) +
            static_cast<int32_t>(floorf(y / spacing))) & 1) != 0;
        return clampUnit(0.5f + (inside ? edge : -edge));
    }
    case Pattern::waves: {
        const float amplitude = spacing * 0.25f;
        const float wavenumber = 3.14159265f / spacing;
        const float offset = y - amplitude * sinf(x * wavenumber);
        const float slope = amplitude * wavenumber * cosf(x * wavenumber);
        return line(nearestMultipleDistance(offset, spacing) / sqrtf(1.0f + slope * slope));
    }
    case Pattern::rings:
        return line(nearestMultipleDistance(sqrtf(x * x + y * y), spacing));
    case Pattern::spiral: {
        const float radius = sqrtf(x * x + y * y);
        const float turn = atan2f(y, x) * (0.15915494f * spacing);
        return line(nearestMultipleDistance(radius - turn, spacing));
    }
    case Pattern::truchet: {
        const int32_t column = static_cast<int32_t>(floorf(x / spacing));
        const int32_t row = static_cast<int32_t>(floorf(y / spacing));
        float lx = x - column * spacing;
        const float ly = y - row * spacing;
        if (truchetFlip(column, row)) lx = spacing - lx;
        const float half = spacing * 0.5f;
        const float first = fabsf(sqrtf(lx * lx + ly * ly) - half);
        const float sx = spacing - lx;
        const float sy = spacing - ly;
        const float second = fabsf(sqrtf(sx * sx + sy * sy) - half);
        return line(fminf(first, second));
    }
    }
    return 0;
}

inline float halftoneRadialRank(int32_t x, int32_t y, float spacing, float cosine, float sine) {
    const float px = x + 0.5f;
    const float py = y + 0.5f;
    const float screenX = px * cosine + py * sine;
    const float screenY = -px * sine + py * cosine;
    const float localX = screenX - floorf(screenX / spacing) * spacing - spacing / 2;
    const float localY = screenY - floorf(screenY / spacing) * spacing - spacing / 2;
    return fminf(1.0f, 3.14159265f * (localX * localX + localY * localY) / (spacing * spacing));
}

struct Quantizer {
    Mode mode = Mode::monochrome;
    int32_t threshold = 128;
    int32_t levels = 16;
    float spacing = 8;
    float cosine = 1;
    float sine = 0;
    float gain = 0;

    explicit Quantizer(const Texture& texture)
        : mode(texture.mode), threshold(texture.threshold), levels(texture.levels),
          spacing(texture.dotSpacing < 2 ? 2.0f : texture.dotSpacing),
          cosine(cosf(texture.angle * 0.017453293f)), sine(sinf(texture.angle * 0.017453293f)),
          gain(texture.dotGain / 100.0f) {}

    // packHalftoneLuminance: true means a black pixel.
    bool halftoneDark(int32_t luminance, int32_t x, int32_t y) const {
        const float coverage = clampUnit(1 - luminance / 255.0f + gain);
        if (coverage <= 0) return false;
        return coverage >= 1 || halftoneRadialRank(x, y, spacing, cosine, sine) < coverage;
    }

    // packGrayscaleLuminance: panel level 0 (black) to 15 (white).
    uint8_t grayscale(int32_t luminance, int32_t x, int32_t y, bool halftone) const {
        const int32_t levelCount = levels < 2 ? 2 : levels > 16 ? 16 : levels;
        int32_t adjusted = luminance + 128 - threshold;
        adjusted = adjusted < 0 ? 0 : adjusted > 255 ? 255 : adjusted;
        const float scaled = adjusted / 255.0f * (levelCount - 1);
        int32_t quantized;
        if (halftone) {
            const int32_t darker = static_cast<int32_t>(floorf(scaled));
            const int32_t lighter = darker + 1 < levelCount - 1 ? darker + 1 : levelCount - 1;
            const float darkCoverage = clampUnit(1 - (scaled - darker) + gain);
            quantized = halftoneRadialRank(x, y, spacing, cosine, sine) < darkCoverage
                ? darker : lighter;
        } else {
            quantized = static_cast<int32_t>(roundf(scaled));
        }
        return static_cast<uint8_t>(roundf(static_cast<float>(quantized) / (levelCount - 1) * 15));
    }

    // Matches PaperGIFEncoder.packedFrame's mode selection.
    uint8_t level(int32_t luminance, int32_t x, int32_t y) const {
        switch (mode) {
        case Mode::threshold:
            return luminance < threshold ? 0 : 15;
        case Mode::monochrome:
            if (levels == 0) return luminance < threshold ? 0 : 15;
            return grayscale(luminance, x, y, false);
        case Mode::halftone:
            return halftoneDark(luminance, x, y) ? 0 : 15;
        case Mode::combined:
            if (levels == 0) {
                int32_t shifted = luminance + 128 - threshold;
                shifted = shifted < 0 ? 0 : shifted > 255 ? 255 : shifted;
                return halftoneDark(shifted, x, y) ? 0 : 15;
            }
            return grayscale(luminance, x, y, true);
        }
        return 15;
    }
};

struct ImageView {
    const uint8_t* pixels = nullptr;
    uint16_t width = 0;
    uint16_t height = 0;
};

// Centered aspect-fill crop, box-filtered into an output of width x height.
struct CoverSampler {
    ImageView image;
    int32_t width = 0;
    int32_t height = 0;
    int32_t cropX = 0;
    int32_t cropY = 0;
    int32_t cropWidth = 1;
    int32_t cropHeight = 1;

    CoverSampler(const ImageView& view, int32_t outputWidth, int32_t outputHeight)
        : image(view), width(outputWidth), height(outputHeight) {
        if (image.pixels == nullptr || width <= 0 || height <= 0) return;
        if (static_cast<int64_t>(image.width) * height > static_cast<int64_t>(image.height) * width) {
            cropHeight = image.height;
            cropWidth = static_cast<int32_t>(
                (static_cast<int64_t>(image.height) * width + height / 2) / height);
        } else {
            cropWidth = image.width;
            cropHeight = static_cast<int32_t>(
                (static_cast<int64_t>(image.width) * height + width / 2) / width);
        }
        cropWidth = cropWidth < 1 ? 1 : cropWidth > image.width ? image.width : cropWidth;
        cropHeight = cropHeight < 1 ? 1 : cropHeight > image.height ? image.height : cropHeight;
        cropX = (image.width - cropWidth) / 2;
        cropY = (image.height - cropHeight) / 2;
    }

    uint8_t sample(int32_t x, int32_t y) const {
        const int32_t left = cropX + x * cropWidth / width;
        int32_t right = cropX + (x + 1) * cropWidth / width;
        const int32_t top = cropY + y * cropHeight / height;
        int32_t bottom = cropY + (y + 1) * cropHeight / height;
        if (right <= left) right = left + 1;
        if (bottom <= top) bottom = top + 1;
        uint32_t total = 0;
        for (int32_t row = top; row < bottom; ++row) {
            const uint8_t* source = image.pixels + static_cast<size_t>(row) * image.width;
            for (int32_t column = left; column < right; ++column) total += source[column];
        }
        return static_cast<uint8_t>(total / static_cast<uint32_t>((right - left) * (bottom - top)));
    }
};

inline bool insideRoundedRect(int32_t x, int32_t y, int32_t width, int32_t height, int32_t radius) {
    const float px = x + 0.5f;
    const float py = y + 0.5f;
    const float cx = px < radius ? radius : px > width - radius ? width - radius : px;
    const float cy = py < radius ? radius : py > height - radius ? height - radius : py;
    const float dx = px - cx;
    const float dy = py - cy;
    return dx * dx + dy * dy <= static_cast<float>(radius) * radius;
}

// Per-pixel panel levels for an idle button; outside the rounded corners stays page white.
struct Renderer {
    const Texture& texture;
    CoverSampler sampler;
    Quantizer quantizer;
    int32_t fill;
    int32_t foreground;
    int32_t width;
    int32_t height;
    int32_t radius;
    int32_t inkPercent;

    Renderer(const Texture& value, const ImageView& image, uint8_t fillLuminance,
             uint8_t foregroundLuminance, int32_t outputWidth, int32_t outputHeight,
             int32_t cornerRadius)
        : texture(value), sampler(image, outputWidth, outputHeight), quantizer(value),
          fill(fillLuminance), foreground(foregroundLuminance), width(outputWidth),
          height(outputHeight), radius(cornerRadius),
          inkPercent(100 - (value.fade > 100 ? 100 : value.fade)) {}

    bool drawable() const {
        return texture.kind == Kind::pattern ||
            (texture.kind == Kind::image && sampler.image.pixels != nullptr);
    }

    int32_t composite(float ink) const {
        return fill + static_cast<int32_t>(lroundf((foreground - fill) * ink * inkPercent / 100.0f));
    }

    uint8_t level(int32_t x, int32_t y) const {
        if (!insideRoundedRect(x, y, width, height, radius)) return 15;
        if (texture.kind == Kind::image && sampler.image.pixels != nullptr) {
            const float darkness = (255 - sampler.sample(x, y)) / 255.0f;
            return quantizer.level(composite(darkness), x, y);
        }
        float ink = 0;
        if (texture.kind == Kind::pattern) {
            const float spacing = texture.scale < 2 ? 2.0f : texture.scale;
            const int32_t lineWidth = texture.lineWidth < 1 ? 1 : texture.lineWidth;
            // Pixel centers sit on integers, so odd-width lines land exactly on pixels.
            const float offset = lineWidth % 2 == 0 ? 0.5f : 0.0f;
            ink = patternCoverage(texture.pattern, x - width / 2 + offset,
                y - height / 2 + offset, spacing, static_cast<float>(lineWidth));
        }
        return static_cast<uint8_t>((composite(ink) * 15 + 127) / 255);
    }
};

inline uint8_t luminance565(uint16_t color) {
    const uint32_t red = ((color >> 11) & 0x1F) * 255 / 31;
    const uint32_t green = ((color >> 5) & 0x3F) * 255 / 63;
    const uint32_t blue = (color & 0x1F) * 255 / 31;
    return static_cast<uint8_t>((red * 299 + green * 587 + blue * 114) / 1000);
}

}  // namespace remote_button_texture
