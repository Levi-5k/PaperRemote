#include "remote_button_texture.h"
#include <cassert>
#include <iostream>

using namespace remote_button_texture;

int main() {
    Kind kind;
    Pattern pattern;
    Mode mode;
    assert(parseKind("image", kind) && kind == Kind::image);
    assert(!parseKind("photo", kind) && !parseKind(nullptr, kind));
    assert(parsePattern("hexagons", pattern) && pattern == Pattern::hexagons);
    assert(parsePattern("truchet", pattern) && pattern == Pattern::truchet);
    assert(!parsePattern("stars", pattern));
    assert(parseMode("combined", mode) && mode == Mode::combined);

    char id[kImageIdBytes];
    assert(normalizeImageId("0a1b2c3d-4e5f-6789-abcd-ef0123456789", id));
    assert(strcmp(id, "0A1B2C3D-4E5F-6789-ABCD-EF0123456789") == 0);
    assert(!normalizeImageId("../../library/remote.json-000000000000", id));
    assert(!normalizeImageId("0A1B2C3D-4E5F-6789-ABCD-EF012345678", id));
    assert(!normalizeImageId("0A1B2C3D/4E5F-6789-ABCD-EF0123456789", id));
    assert(!normalizeImageId(nullptr, id));

    uint8_t header[kImageHeaderBytes] = {'P', 'B', 'G', 'I', 1, 0, 3, 0, 2, 0};
    uint16_t width = 0, height = 0;
    assert(parseImageHeader(header, kImageHeaderBytes + 6, width, height) && width == 3 && height == 2);
    assert(!parseImageHeader(header, kImageHeaderBytes + 5, width, height));
    header[4] = 2;
    assert(!parseImageHeader(header, kImageHeaderBytes + 6, width, height));
    header[4] = 1;
    header[6] = 0x1D; header[7] = 0x02;  // 541 px
    assert(!parseImageHeader(header, kImageHeaderBytes + 541 * 2, width, height));

    // Quantization matches PaperGIFEncoder (threshold 128, 16 levels unless noted).
    Texture texture;
    texture.kind = Kind::image;
    Quantizer quantizer(texture);
    assert(quantizer.level(0, 0, 0) == 0);
    assert(quantizer.level(255, 0, 0) == 15);
    assert(quantizer.level(128, 0, 0) == 8);
    texture.levels = 4;
    assert(Quantizer(texture).level(128, 0, 0) == 10);
    texture.levels = 0;
    assert(Quantizer(texture).level(127, 0, 0) == 0 && Quantizer(texture).level(128, 0, 0) == 15);
    texture.mode = Mode::threshold;
    texture.threshold = 200;
    assert(Quantizer(texture).level(199, 0, 0) == 0 && Quantizer(texture).level(200, 0, 0) == 15);
    texture.mode = Mode::halftone;
    assert(Quantizer(texture).level(0, 3, 3) == 0 && Quantizer(texture).level(255, 3, 3) == 15);
    texture.dotGain = -50;
    assert(Quantizer(texture).level(150, 5, 5) == 15);
    texture.dotGain = 50;
    assert(Quantizer(texture).level(100, 5, 5) == 0);

    // Pattern geometry, relative to the button center.
    assert(patternCoverage(Pattern::grid, 0, 5, 16, 1) == 1);
    assert(patternCoverage(Pattern::grid, 1, 5, 16, 1) == 0);
    assert(patternCoverage(Pattern::grid, 8, 8, 16, 1) == 0);
    assert(patternCoverage(Pattern::rings, 0, 0, 16, 1) == 1);
    assert(patternCoverage(Pattern::rings, 8, 0, 16, 1) == 0);
    assert(patternCoverage(Pattern::hexagons, 0, 0, 20, 1) == 0);
    assert(patternCoverage(Pattern::hexagons, 10, 0, 20, 1) == 1);
    assert(patternCoverage(Pattern::hexagons, -10, 0, 20, 1) == 1);
    assert(patternCoverage(Pattern::triangles, 16, 0, 16, 1) == 1);
    assert(patternCoverage(Pattern::dots, 0, 0, 16, 1) == 1);
    assert(patternCoverage(Pattern::dots, 8, 8, 16, 1) == 0);
    assert(patternCoverage(Pattern::checker, 4, 4, 16, 1) == 0);
    assert(patternCoverage(Pattern::checker, 20, 4, 16, 1) == 1);
    for (int index = 0; index <= static_cast<int>(Pattern::truchet); ++index) {
        int inked = 0;
        for (int y = -40; y < 40; ++y) {
            for (int x = -60; x < 60; ++x) {
                const float coverage = patternCoverage(
                    static_cast<Pattern>(index), x + 0.5f, y + 0.5f, 16, 2);
                assert(coverage >= 0 && coverage <= 1);
                inked += coverage > 0.5f;
            }
        }
        // Every pattern draws something but leaves most of the button clear.
        assert(inked > 200 && inked < 120 * 80 * 3 / 4);
    }

    // Aspect-fill sampling.
    const uint8_t checker[] = {0, 255, 255, 0};
    ImageView view;
    view.pixels = checker; view.width = 2; view.height = 2;
    assert(CoverSampler(view, 1, 1).sample(0, 0) == 127);
    assert(CoverSampler(view, 4, 4).sample(0, 0) == 0 && CoverSampler(view, 4, 4).sample(3, 0) == 255);
    const uint8_t wide[] = {10, 20, 30, 40, 50, 60};
    view.pixels = wide; view.width = 6; view.height = 1;
    CoverSampler square(view, 1, 1);
    assert(square.cropWidth == 1 && square.cropX == 2 && square.sample(0, 0) == 30);

    // Renderer: corners stay white, fade 100 hides the pattern, filled style inverts ink.
    Texture plain;
    Renderer none(plain, ImageView(), 255, 0, 100, 60, 10);
    assert(none.level(0, 0) == 15 && none.level(50, 30) == 15);
    Texture rings;
    rings.kind = Kind::pattern;
    rings.pattern = Pattern::rings;
    rings.fade = 0;
    Renderer ringRenderer(rings, ImageView(), 255, 0, 100, 60, 10);
    assert(ringRenderer.level(50, 30) == 0 && ringRenderer.level(58, 30) == 15);
    Renderer invertedRings(rings, ImageView(), 0, 255, 100, 60, 10);
    assert(invertedRings.level(50, 30) == 15 && invertedRings.level(58, 30) == 0);
    rings.fade = 100;
    assert(Renderer(rings, ImageView(), 255, 0, 100, 60, 10).level(50, 30) == 15);
    rings.fade = 50;
    const uint8_t halfway = Renderer(rings, ImageView(), 255, 0, 100, 60, 10).level(50, 30);
    assert(halfway > 5 && halfway < 10);

    Texture image;
    image.kind = Kind::image;
    image.fade = 0;
    image.levels = 16;
    const uint8_t black[] = {0, 0, 0, 0};
    view.pixels = black; view.width = 2; view.height = 2;
    assert(Renderer(image, view, 255, 0, 40, 40, 4).level(20, 20) == 0);
    assert(!Renderer(image, ImageView(), 255, 0, 40, 40, 4).drawable());
    assert(luminance565(0xFFFF) == 255 && luminance565(0) == 0);

    std::cout << "PASS: remote button textures, patterns and image conversion.\n";
}
