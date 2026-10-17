#include "../include/reference_inputs.h"
#include <cassert>
#include <cstdio>

uint32_t now = 0;
int pins[40]{};
int analog = 0;
uint32_t millis() { return now; }
void pinMode(int, int) {}
int digitalRead(int pin) { return pins[pin]; }
int analogRead(int) { return analog; }

int main() {
    using namespace paper_board;
    pins[PAPERGIF_BUTTON_PIN] = 1;
    ReferenceInputs inputs;
    inputs.begin();
    InputEvent event;
    assert(!inputs.poll(event));
    pins[PAPERGIF_BUTTON_PIN] = 0;
    assert(!inputs.poll(event));
    now += 19;
    assert(!inputs.poll(event));
    ++now;
    assert(inputs.poll(event) && !std::strcmp(event.event, "press"));
    const uint32_t pressSequence = event.sequence;
    now += 599;
    assert(!inputs.poll(event));
    ++now;
    assert(inputs.poll(event) && !std::strcmp(event.event, "hold"));
    assert(event.sequence > pressSequence);
    assert(!inputs.poll(event));
    pins[PAPERGIF_BUTTON_PIN] = 1;
    assert(!inputs.poll(event));
    now += 20;
    assert(inputs.poll(event) && !std::strcmp(event.event, "release"));
    const int negative[] = {1,3,2,0}, positive[] = {2,3,1,0};
    for (int state : negative) {
        pins[PAPERGIF_ENCODER_A_PIN] = state >> 1;
        pins[PAPERGIF_ENCODER_B_PIN] = state & 1;
        const bool emitted = inputs.poll(event);
        if (state == 0) assert(emitted && event.value == -1 && !std::strcmp(event.event, "rotate"));
        else assert(!emitted);
    }
    for (int state : positive) {
        pins[PAPERGIF_ENCODER_A_PIN] = state >> 1;
        pins[PAPERGIF_ENCODER_B_PIN] = state & 1;
        const bool emitted = inputs.poll(event);
        if (state == 0) assert(emitted && event.value == 1);
        else assert(!emitted);
    }
    analog = 2048;
    now += 25;
    assert(inputs.poll(event) && event.value == 2048 && !std::strcmp(event.event, "change"));
    analog = 2050;
    now += 25;
    assert(!inputs.poll(event)); // Deadband prevents ADC noise from sending actions.
    analog = 4095;
    now += 25;
    assert(inputs.poll(event) && event.value == 4095);
    analog = 0;
    now += 25;
    assert(inputs.poll(event) && event.value == 0);
    pins[PAPERGIF_BUTTON_PIN] = 0;
    inputs.poll(event);
    now += 20;
    assert(inputs.poll(event));
    inputs.release();
    now += 1000;
    assert(!inputs.poll(event)); // A held button cannot restart an action after disconnect.
    pins[PAPERGIF_BUTTON_PIN] = 1;
    assert(!inputs.poll(event));
    inputs.poll(event);
    now += 20;
    assert(!inputs.poll(event));
    pins[PAPERGIF_BUTTON_PIN] = 0;
    assert(!inputs.poll(event));
    now += 20;
    assert(inputs.poll(event) && !std::strcmp(event.event, "press"));
    puts("Reference GPIO debounce, hold/release, encoder, ADC, and disconnect tests passed");
}
