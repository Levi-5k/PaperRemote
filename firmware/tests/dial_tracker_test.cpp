#include "../include/dial_tracker.h"
#include "../include/hardware_binding.h"
#include <cassert>
#include <cstdio>
#include <limits>

using namespace paper_board;
static uint16_t raw(double angle) {
    return uint16_t(std::round(std::fmod(angle + 36000, 360) * 16384 / 360)) % 16384;
}
int main() {
    DialTracker dial;
    DialConfiguration config;
    config.jitter = 0;
    config.step = 0.01;
    assert(dial.configure(config));
    double value = 0;
    assert(!dial.update(raw(350), value));
    assert(dial.update(raw(359), value) && value > 16000);
    assert(dial.update(raw(2), value) && value == 16383);
    assert(!dial.update(raw(30), value));  // Stop discards overshoot.
    assert(dial.update(raw(29), value) && value < 16383 && value > 16000);
    dial.zero();
    assert(dial.positionDegrees() == 0);
    assert(!dial.update(raw(28), value));
    assert(dial.update(raw(29), value) && value > 0 && value < 100);

    config.mode = DialMode::multi;
    config.turns = 3;
    assert(dial.configure(config));
    assert(!dial.update(raw(0), value));
    for (int degrees = 90; degrees <= 1080; degrees += 90)
        assert(dial.update(raw(degrees), value));
    assert(value == 16383 && std::abs(dial.positionDegrees() - 1080) < 0.1);
    assert(!dial.update(raw(1170), value));
    assert(dial.update(raw(1160), value) && value < 16383);
    const double beforePrecision = dial.positionDegrees();
    config.step = 1;
    assert(dial.configure(config) && dial.positionDegrees() == beforePrecision);
    dial.resetSensor();
    assert(!dial.update(raw(1160), value));
    assert(dial.positionDegrees() == beforePrecision);
    config.step = 0.01;

    config.mode = DialMode::continuous;
    config.turns = 1;
    assert(dial.configure(config));
    assert(!dial.update(raw(350), value));
    assert(dial.update(raw(10), value) && value > 900 && value < 920);
    assert(dial.update(raw(350), value) && value < -900 && value > -920);
    config.turns = -1;  // End stop on the other side: counterclockwise increases.
    assert(dial.configure(config));
    assert(!dial.update(raw(350), value));
    assert(dial.update(raw(10), value) && value < 0);
    assert(dial.update(raw(330), value) && value > 0);

    config.mode = DialMode::single;
    config.start = 90;
    config.sweep = -90;  // End stop 90 degrees counterclockwise of the start.
    config.jitter = 0;
    assert(dial.configure(config));
    assert(!dial.update(raw(60), value));
    assert(std::abs(dial.positionDegrees() - 30) < 0.01);
    assert(dial.update(raw(30), value) && std::abs(dial.positionDegrees() - 60) < 0.01);
    assert(dial.update(raw(120), value) && dial.positionDegrees() == 0);
    config.sweep = 0.5;
    assert(!dial.configure(config));
    config.sweep = 360;

    config.mode = DialMode::continuous;
    config.start = 0;
    config.turns = 1;
    config.jitter = 0.5;
    assert(dial.configure(config));
    assert(!dial.update(raw(0), value));
    for (int i = 0; i < 100; ++i) {
        assert(!dial.update(raw(i % 2 ? 0.2 : -0.2), value));
    }
    assert(dial.positionDegrees() == 0);  // Alternating noise never ratchets.
    for (int i = 1; i <= 100; ++i) dial.update(raw(i * 0.02), value);
    assert(dial.positionDegrees() > 1.4 && dial.positionDegrees() < 1.6);  // Slow movement survives.
    config.step = 0;
    assert(!dial.configure(config));
    config.step = 0.1;
    config.turns = std::numeric_limits<double>::quiet_NaN();
    assert(!dial.configure(config));

    BindingState binding;
    binding.mode = BindingMode::absolute;
    binding.value = 50;
    const auto& input = superminiS3Mt6701().inputs[2];
    for (uint32_t i = 1; i <= 10; ++i) {
        assert(applyInput(binding, input, {"dial-1", "change", 16.383, i, true}, value));
    }
    assert(value == 51);  // Sub-step relative movements accumulate.
    binding.value = 100;
    binding.remainder = 0;
    assert(applyInput(binding, input, {"dial-1", "change", 16383, 11, true}, value) && value == 100);
    assert(applyInput(binding, input, {"dial-1", "change", -163.83, 12, true}, value) && value == 99);
    DialConfiguration rates;
    assert(rates.rate == 75 && !rates.lowLatency && rates.valid());
    rates.rate = 500; assert(rates.valid());
    rates.rate = 14; assert(!rates.valid());
    rates.rate = 501; assert(!rates.valid());
    assert(rates.jitter == 0.05 && rates.step == 0.01);

    AngleAverager average;
    for (uint16_t raw : {100, 102, 98, 100}) average.add(raw);
    assert(average.samples() == 4 && std::abs(average.take() - 100) < 1e-9);
    assert(average.samples() == 0);
    for (uint16_t raw : {16382, 16383, 0, 1}) average.add(raw);  // Across 359 -> 0 degrees.
    const double wrapped = average.take();
    assert(std::abs(wrapped - 16383.5) < 1e-9);
    for (uint16_t raw : {1, 0, 16383}) average.add(raw);
    assert(std::abs(average.take() - 0) < 1e-9 || std::abs(average.take() - 16384) < 1e-9);
    // Sensor noise averages out, so a still dial with the finer default filter stays silent.
    DialTracker still;
    assert(still.configure(DialConfiguration{}));
    assert(!still.update(8000.0, value));
    for (int window = 0; window < 200; ++window) {
        for (int i = 0; i < 13; ++i) average.add(uint16_t(8000 + (i * 7 + window) % 5 - 2));
        assert(!still.update(average.take(), value));
    }
    // Fractional counts carry the averaged resolution into the tracker.
    assert(still.update(8000.0 + 0.25 * 16384 / 360, value));
    puts("Dial zero-crossing, soft stops, multi-turn, relative, end-stop side, jitter and precision tests passed");
}
