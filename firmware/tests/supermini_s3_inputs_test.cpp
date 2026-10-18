#include "../include/supermini_s3_board.h"
#include <cassert>
#include <cstdio>
#include <cstring>

uint32_t now = 0;
int pins[40]{};
bool mt6701Present = true;
uint16_t mt6701RawAngle = 16384 - 1000;  // reports 1000 after mirroring
uint32_t wireClock = 0;
int wireSDA = -1, wireSCL = -1;
uint8_t wireAddress = 0, wireRegister = 0;
uint8_t response[2]{};
int responseIndex = 0, responseCount = 0;
TwoWire Wire;

uint32_t millis() { return now; }
uint32_t micros() { return now * 1000; }
void pinMode(int, int) {}
int digitalRead(int pin) { return pins[pin]; }
int analogRead(int) { return 0; }
void TwoWire::begin(int sda, int scl) { wireSDA = sda; wireSCL = scl; }
void TwoWire::setClock(uint32_t frequency) { wireClock = frequency; }
void TwoWire::beginTransmission(uint8_t address) { wireAddress = address; }
size_t TwoWire::write(uint8_t value) { wireRegister = value; return 1; }
uint8_t TwoWire::endTransmission(bool) { return mt6701Present ? 0 : 4; }
uint8_t TwoWire::requestFrom(uint8_t address, uint8_t size) {
    if (!mt6701Present || address != 0x06 || wireRegister != 0x03 || size != 2) return 0;
    response[0] = uint8_t(mt6701RawAngle >> 6);
    response[1] = uint8_t((mt6701RawAngle & 0x3f) << 2);
    responseIndex = 0;
    responseCount = 2;
    return 2;
}
int TwoWire::available() { return responseCount - responseIndex; }
int TwoWire::read() { return responseIndex < responseCount ? response[responseIndex++] : -1; }

int main() {
    using namespace paper_board;
    pins[PAPERGIF_SUPERMINI_BUTTON_1_PIN] = 1;
    pins[PAPERGIF_SUPERMINI_BUTTON_2_PIN] = 1;
    SuperMiniS3Inputs inputs;
    inputs.begin();
    assert(wireSDA == 13 && wireSCL == 12 && wireClock == 400000);
    assert(wireAddress == mt6701Address && wireRegister == mt6701AngleHighRegister);
    assert(superminiS3Mt6701().inputCount == 3);
    assert(!std::strcmp(superminiS3Mt6701().inputs[2].kind, "dial"));
    assert(superminiS3Mt6701().inputs[2].maximum == 16383);
    uint16_t diagnosticAngle = 0;
    SuperMiniS3Board board;
    assert(board.readDialForDiagnostics(diagnosticAngle) && diagnosticAngle == 1000);
    assert(!board.buttonPressedForDiagnostics(0));
    pins[PAPERGIF_SUPERMINI_BUTTON_2_PIN] = 0;
    assert(board.buttonPressedForDiagnostics(1));
    pins[PAPERGIF_SUPERMINI_BUTTON_2_PIN] = 1;

    InputEvent event;
    assert(!inputs.poll(event));
    pins[PAPERGIF_SUPERMINI_BUTTON_1_PIN] = 0;
    assert(!inputs.poll(event));
    now += 20;
    assert(inputs.poll(event) && !std::strcmp(event.inputID, "button-1"));
    assert(!std::strcmp(event.event, "press"));
    pins[PAPERGIF_SUPERMINI_BUTTON_2_PIN] = 0;
    assert(!inputs.poll(event));
    now += 20;
    assert(inputs.poll(event) && !std::strcmp(event.inputID, "button-2"));

    // The dial is sampled every millisecond and averaged over 5 ms output periods;
    // run enough polls to complete a full window at the new angle.
    auto settle = [&](InputEvent& last) {
        bool emitted = false;
        for (int i = 0; i < 12; ++i) {
            now += 1;
            InputEvent next;
            if (inputs.poll(next)) { last = next; emitted = true; }
        }
        return emitted;
    };
    mt6701RawAngle = 16384 - 1040;  // reported angles are mirrored
    assert(settle(event) && !std::strcmp(event.inputID, "dial-1"));
    assert(!std::strcmp(event.event, "change") && event.value > 1000 && event.value < 1050);
    mt6701RawAngle = 16384 - 1039;  // A one-count (0.022 deg) reversal is inside the 0.05 deg filter.
    assert(!settle(event));
    mt6701RawAngle = 4;
    // This is a small backwards movement across zero, not a full clockwise turn.
    assert(settle(event) && event.value < 10);
    mt6701RawAngle = 3;
    assert(!settle(event));  // Noise inside the angular hysteresis band.
    mt6701RawAngle = 4;
    assert(!settle(event));
    // Readings alternating within one window average out instead of emitting.
    for (int i = 0; i < 24; ++i) {
        mt6701RawAngle = i % 2 ? 2 : 6;
        now += 1;
        assert(!inputs.poll(event));
    }

    inputs.release();
    now += 20;
    assert(!inputs.poll(event));
    pins[PAPERGIF_SUPERMINI_BUTTON_1_PIN] = 1;
    pins[PAPERGIF_SUPERMINI_BUTTON_2_PIN] = 1;
    inputs.poll(event);
    now += 20;
    assert(!inputs.poll(event));
    mt6701Present = false;
    now += 20;
    assert(!inputs.poll(event));

    puts("SuperMini button, MT6701 angle, wraparound, and disconnect tests passed");
}