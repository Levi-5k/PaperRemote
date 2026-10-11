#include "remote_button_style.h"
#include <cassert>
#include <iostream>

int main() {
    using namespace remote_button_style;

    assert(resolve(nullptr, nullptr) == Background::outline);
    assert(resolve("", "") == Background::outline);
    assert(resolve("unknown", nullptr) == Background::outline);
    assert(resolve("filled", nullptr) == Background::filled);
    assert(resolve("filled", "") == Background::filled);
    assert(resolve("filled", "bogus") == Background::filled);
    assert(resolve("filled", "shaded") == Background::shaded);
    assert(resolve("shaded", "outline") == Background::outline);
    assert(resolve(nullptr, "borderless") == Background::borderless);

    const Background all[] = {
        Background::outline, Background::filled, Background::shaded, Background::borderless};
    for (Background background : all) {
        const Colors idle = colors(background, false);
        const Colors active = colors(background, true);
        assert(idle.fill != idle.foreground);
        assert(active.fill != active.foreground);
        assert(idle.fill != active.fill);
    }

    Colors c = colors(Background::outline, false);
    assert(c.fill == kWhite && c.foreground == kBlack && c.border);
    c = colors(Background::outline, true);
    assert(c.fill == kBlack && c.foreground == kWhite && !c.border);
    c = colors(Background::filled, false);
    assert(c.fill == kBlack && c.foreground == kWhite && !c.border);
    c = colors(Background::filled, true);
    assert(c.fill == kWhite && c.foreground == kBlack && c.border);
    c = colors(Background::shaded, false);
    assert(c.fill == kShade && c.foreground == kBlack && !c.border);
    c = colors(Background::borderless, false);
    assert(c.fill == kWhite && c.foreground == kBlack && !c.border);

    std::cout << "PASS: remote button background resolution and colors.\n";
}
