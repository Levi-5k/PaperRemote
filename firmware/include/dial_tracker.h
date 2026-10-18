#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace paper_board {
enum class DialMode { single, multi, continuous };

struct DialConfiguration {
    DialMode mode = DialMode::single;
    double start = 0;
    // Signed travel to the end stop: positive is clockwise, negative is
    // counterclockwise, so moving the end stop past the start reverses the dial.
    double sweep = 360;
    double turns = 3;
    double step = 0.01;  // Percent of the output range.
    double jitter = 0.05;  // Degrees of sensor hysteresis, applied after averaging.
    // Low latency streams change-only values over UDP/Bluetooth, at most `rate` per second.
    bool lowLatency = false;
    double rate = 75;

    bool valid() const {
        return (mode == DialMode::single || mode == DialMode::multi || mode == DialMode::continuous) &&
            std::isfinite(start) && start >= 0 && start <= 359.9 &&
            std::isfinite(sweep) && std::abs(sweep) >= 1 && std::abs(sweep) <= 360 &&
            std::isfinite(turns) && std::abs(turns) >= 0.1 && std::abs(turns) <= 100 &&
            std::isfinite(step) && step >= 0.01 && step <= 10 &&
            std::isfinite(jitter) && jitter >= 0 && jitter <= 5 &&
            std::isfinite(rate) && rate >= 15 && rate <= 500;
    }
    double span() const { return std::abs(mode == DialMode::single ? sweep : turns) * (mode == DialMode::single ? 1 : 360); }
    bool counterclockwise() const { return (mode == DialMode::single ? sweep : turns) < 0; }
};

// Mean of the 14-bit readings taken during one output period. Each reading is
// unwrapped against the previous one, so a window spanning 359 -> 0 degrees
// averages to ~0 rather than 180.
class AngleAverager {
    double first = 0, offset = 0, total = 0;
    uint16_t last = 0;
    uint32_t count = 0;
public:
    void add(uint16_t raw) {
        if (count == 0) {
            first = raw;
            offset = total = 0;
        } else {
            int delta = int(raw) - int(last);
            if (delta > 8192) delta -= 16384;
            else if (delta < -8192) delta += 16384;
            offset += delta;
            total += offset;
        }
        last = raw;
        ++count;
    }
    uint32_t samples() const { return count; }
    // Mean angle in raw counts, 0 <= mean < 16384.
    double take() {
        const double mean = std::fmod(first + total / count + 16384, 16384);
        count = 0;
        return mean;
    }
    void clear() { count = 0; }
};

// Unwrap before filtering. Clipping discards overshoot so reversing at a soft
// stop responds immediately, rather than winding back through discarded turns.
class DialTracker {
    DialConfiguration settings;
    bool initialized = false, hasPosition = false;
    double previous = 0, sensor = 0, accepted = 0, position = 0, emitted = 0;

    double quantized() const {
        const double quantum = settings.span() * settings.step / 100;
        const double result = std::round(position / quantum) * quantum;
        return settings.mode == DialMode::continuous ? result
            : std::max(0.0, std::min(settings.span(), result));
    }
public:
    const DialConfiguration& configuration() const { return settings; }
    bool configure(const DialConfiguration& candidate) {
        if (!candidate.valid()) return false;
        const bool newOrigin = candidate.mode != settings.mode || candidate.start != settings.start ||
            candidate.counterclockwise() != settings.counterclockwise();
        settings = candidate;
        if (newOrigin) {
            initialized = false;
            hasPosition = false;
        } else if (settings.mode != DialMode::continuous) {
            position = std::max(0.0, std::min(settings.span(), position));
        }
        emitted = quantized();
        return true;
    }
    void resetSensor() { initialized = false; }
    bool ready() const { return initialized; }
    double positionDegrees() const { return position; }
    double shaftAngle() const { return previous; }
    double outputPercent() const {
        return quantized() / settings.span() * 100;
    }
    void zero() {
        position = emitted = 0;
        accepted = sensor;
    }
    // `raw` is in 14-bit sensor counts; fractional counts come from averaging.
    bool update(double raw, double& value) {
        const double angle = std::fmod(raw * 360 / 16384, 360);
        if (!initialized) {
            previous = angle;
            sensor = accepted = 0;
            double phase = std::fmod((settings.counterclockwise() ? settings.start - angle
                : angle - settings.start) + 360, 360);
            if (!hasPosition) {
                position = settings.mode == DialMode::single
                    ? std::min(settings.span(), phase) : 0;
            }
            hasPosition = true;
            emitted = quantized();
            initialized = true;
            return false;
        }
        double delta = angle - previous;
        previous = angle;
        if (delta > 180) delta -= 360;
        else if (delta < -180) delta += 360;
        sensor += settings.counterclockwise() ? -delta : delta;
        // A hysteresis band, not per-sample rounding: slow movements accumulate
        // and alternating noise cannot ratchet the position forward.
        const double difference = sensor - accepted;
        if (std::abs(difference) <= settings.jitter) return false;
        const double movement = difference - std::copysign(settings.jitter, difference);
        accepted += movement;
        position += movement;
        if (settings.mode != DialMode::continuous)
            position = std::max(0.0, std::min(settings.span(), position));
        const double next = quantized();
        if (std::abs(next - emitted) < 1e-9) return false;
        value = (settings.mode == DialMode::continuous ? next - emitted : next)
            / settings.span() * 16383;
        emitted = next;
        return true;
    }
};
}  // namespace paper_board
