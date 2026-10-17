#include "../include/supermini_s3_board.h"
#include <cassert>
#include <cstdio>
#include <cstring>

uint32_t now = 0;
int pins[40]{};
bool mt6701Present = true;
uint16_t mt6701RawAngle = 1000;
uint32_t wireClock = 0;
int wireSDA = -1, wireSCL = -1;
uint8_t wireAddress = 0, wireRegister = 0;
uint8_t response[2]{};
int responseIndex = 0, responseCount = 0;
TwoWire Wire;

uint32_t millis() { return now; }
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

    mt6701RawAngle = 1040;
    now += 20;
    assert(inputs.poll(event) && !std::strcmp(event.inputID, "dial-1"));
    assert(!std::strcmp(event.event, "change") && event.value == 1040);
    mt6701RawAngle = 1042;
    now += 20;
    assert(!inputs.poll(event));
    mt6701RawAngle = 16380;
    now += 20;
    assert(inputs.poll(event) && event.value == 16380);
    mt6701RawAngle = 3;
    now += 20;
    assert(inputs.poll(event) && event.value == 3);

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