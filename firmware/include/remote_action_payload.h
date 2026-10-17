#pragma once
#include <ArduinoJson.h>
#include <cstdint>
#include <cstring>

// Shared by the M5Paper dispatcher and native physical-input dispatcher.
template <typename Document, typename Action>
void writeRemoteActionPayload(Document& document, const Action& action) {
    document["type"] = action.type;
    document["host"] = action.host;
    document["text"] = action.text;
    document["value"] = action.value;
    if (strcmp(action.type, "netHomeTemperature") == 0 ||
        strcmp(action.type, "openBuilds") == 0 ||
        strcmp(action.type, "netHomeClimate") == 0) {
        document["valueTenths"] = action.valueTenths;
    }
    auto modifiers = document["modifiers"].template to<JsonArray>();
    for (uint8_t i = 0; i < action.modifierCount; ++i) modifiers.add(action.modifiers[i]);
}
