#pragma once

#include <ArduinoJson.h>
#include "hardware_binding.h"

namespace paper_board {
constexpr size_t maxBindings = 24;
struct NativeAction {
    char type[32] = {};
    char host[64] = {};
    char text[192] = {};
    char computerId[40] = {};
    char httpMethod[5] = "POST";
    char httpBody[512] = {};
    int32_t value = 0;
    int32_t valueTenths = 0;
    char modifiers[4][12] = {};
    uint8_t modifierCount = 0;
};
struct HardwareBinding {
    char inputID[32] = {};
    char event[12] = {};
    int8_t direction = 0;
    BindingState state;
    NativeAction action;
};
struct NativeProfile {
    HardwareBinding bindings[maxBindings];
    size_t count = 0;
};
template <size_t N>
bool copyField(char (&out)[N], JsonVariantConst value, const char* fallback = "") {
    const char* text = value.isNull() ? fallback : value.as<const char*>();
    if (!text || std::strlen(text) >= N) return false;
    std::strcpy(out, text);
    return true;
}
inline bool companionAction(const char* type) {
    const char* supported[] = {"macMedia", "macKey", "macOpen", "macShortcut", "macScript",
        "openBuilds", "netHomePower", "netHomeTemperature", "netHomeTemperatureStep",
        "netHomeMode", "netHomeFan", "netHomeClimate", "module"};
    for (auto item : supported) if (std::strcmp(type, item) == 0) return true;
    return false;
}
inline bool supportedNativeAction(const char* type) {
    return companionAction(type) || !std::strcmp(type, "iPhoneMedia") ||
        !std::strcmp(type, "localHTTP") || !std::strcmp(type, "wledPower") ||
        !std::strcmp(type, "wledPreset") || !std::strcmp(type, "wledBrightness");
}
inline bool parseAction(JsonVariantConst json, NativeAction& action) {
    if (!json.is<JsonObjectConst>() ||
        !json["type"].is<const char*>() || !json["host"].is<const char*>() ||
        !json["text"].is<const char*>() ||
        !copyField(action.type, json["type"]) || action.type[0] == 0 ||
        !copyField(action.host, json["host"]) || !copyField(action.text, json["text"]) ||
        !copyField(action.computerId, json["computerID"]) ||
        !copyField(action.httpMethod, json["httpMethod"], "POST") ||
        !copyField(action.httpBody, json["httpBody"])) return false;
    if (!supportedNativeAction(action.type)) return false;
    if (!json["value"].is<int32_t>()) return false;
    action.value = json["value"];
    action.valueTenths = json["valueTenths"].is<int32_t>()
        ? json["valueTenths"].as<int32_t>()
        : static_cast<int32_t>(std::fmax(INT32_MIN, std::fmin(INT32_MAX, double(action.value) * 10)));
    if (!json["modifiers"].is<JsonArrayConst>() || json["modifiers"].size() > 4) return false;
    for (auto modifier : json["modifiers"].as<JsonArrayConst>()) {
        if (!copyField(action.modifiers[action.modifierCount++], modifier)) return false;
    }
    return true;
}
inline bool parseNativeProfile(JsonDocument& json, NativeProfile& output, const BoardInfo& board,
                               const char** reason = nullptr) {
    if (reason) *reason = "invalid_profile";
    output.count = 0;
    const int version = json["version"] | 0;
    if ((version != 6 && version != 7) || !json["pages"].is<JsonArray>() ||
        json["pages"].size() > board.maxPages ||
        (!json["hardwareBindings"].isNull() && version != 7)) return false;
    for (JsonObjectConst page : json["pages"].as<JsonArrayConst>()) {
        if (!page["controls"].is<JsonArrayConst>() || page["controls"].size() > board.maxControls)
            return false;
        // There is no touch surface on this target. Never silently accept invisible controls.
        if (!board.display && page["controls"].size()) return false;
    }
    if (version == 6) return true;
    if (!json["hardwareBindings"].is<JsonArray>() ||
        json["hardwareBindings"].size() > maxBindings) return false;
    for (JsonObjectConst item : json["hardwareBindings"].as<JsonArrayConst>()) {
        auto& binding = output.bindings[output.count];
        binding = HardwareBinding{};
        if (!supportedNativeAction(item["action"]["type"] | "")) {
            if (reason) *reason = "unsupported_action";
            return false;
        }
        if (!copyField(binding.inputID, item["inputID"]) ||
            !copyField(binding.event, item["event"]) ||
            !parseAction(item["action"], binding.action)) return false;
        const auto* input = findInput(board, binding.inputID, binding.event);
        if (!input) return false;
        const char* mode = item["mode"] | "";
        if (!std::strcmp(mode, "relative")) {
            if (std::strcmp(binding.event, "rotate")) return false;
            binding.state.mode = BindingMode::relative;
        } else if (!std::strcmp(mode, "absolute")) {
            if (std::strcmp(binding.event, "change") || input->maximum <= input->minimum) return false;
            binding.state.mode = BindingMode::absolute;
        } else if (std::strcmp(mode, "action")) return false;
        if (binding.state.mode != BindingMode::action &&
            std::strcmp(binding.action.type, "wledBrightness") &&
            std::strcmp(binding.action.type, "netHomeTemperature") &&
            !((!std::strcmp(binding.action.type, "macMedia") ||
                !std::strcmp(binding.action.type, "iPhoneMedia")) &&
                !std::strcmp(binding.action.text, "volume"))) return false;
        if (!item["direction"].isNull()) {
            if (binding.state.mode != BindingMode::action || std::strcmp(binding.event, "rotate")) return false;
            const char* direction = item["direction"] | "";
            if (!std::strcmp(direction, "negative")) binding.direction = -1;
            else if (!std::strcmp(direction, "positive")) binding.direction = 1;
            else return false;
        }
        if (!item["minimum"].is<double>() || !item["maximum"].is<double>() ||
            !item["step"].is<double>()) return false;
        binding.state.minimum = item["minimum"];
        binding.state.maximum = item["maximum"];
        binding.state.step = item["step"];
        binding.state.value = binding.action.value;
        if (!validBinding(binding.state)) return false;
        if (binding.state.mode != BindingMode::action) {
            const bool volume = !std::strcmp(binding.action.type, "macMedia") ||
                !std::strcmp(binding.action.type, "iPhoneMedia");
            const bool brightness = !std::strcmp(binding.action.type, "wledBrightness");
            if ((volume || brightness) && (binding.state.minimum < 0 ||
                binding.state.maximum > (brightness ? 255 : 100))) return false;
        }
        binding.state.value = boundValue(binding.state.value, binding.state);
        for (size_t i = 0; i < output.count; ++i)
            if (!std::strcmp(output.bindings[i].inputID, binding.inputID) &&
                !std::strcmp(output.bindings[i].event, binding.event) &&
                (!output.bindings[i].direction || !binding.direction ||
                    output.bindings[i].direction == binding.direction)) return false;
        ++output.count;
    }
    return true;
}
// Bindings express media volume/seek as 0-100 percent, but computers and phones receive
// those actions on the M5Paper slider's 0-255 scale.
inline double mediaWireValue(const NativeAction& action, double percent) {
    const bool media = !std::strcmp(action.type, "macMedia") || !std::strcmp(action.type, "iPhoneMedia");
    const bool scaled = !std::strcmp(action.text, "volume") || !std::strcmp(action.text, "seek");
    return media && scaled ? std::fmax(0.0, std::fmin(255.0, percent * 255 / 100)) : percent;
}

template <typename Dispatch>
void dispatchHardwareInput(NativeProfile& profile, const BoardInfo& board, const InputEvent& event,
                           Dispatch dispatch) {
    for (size_t i = 0; i < profile.count; ++i) {
        auto& binding = profile.bindings[i];
        if (std::strcmp(binding.inputID, event.inputID) || std::strcmp(binding.event, event.event)) continue;
        if (!std::strcmp(event.event, "rotate") && (event.value == 0 ||
            (binding.direction < 0 && event.value >= 0) || (binding.direction > 0 && event.value <= 0))) continue;
        const auto* input = findInput(board, event.inputID, event.event);
        BindingState next = binding.state;
        double value = 0;
        if (!input || !applyInput(next, *input, event, value)) continue;
        NativeAction action = binding.action;
        if (next.mode != BindingMode::action) {
            action.value = static_cast<int32_t>(std::round(mediaWireValue(action, value)));
            action.valueTenths = static_cast<int32_t>(std::fmax(INT32_MIN, std::fmin(INT32_MAX, value * 10)));
            if (next.value == binding.state.value) {
                binding.state = next;
                continue;
            }
        }
        if (dispatch(binding, action)) binding.state = next;
    }
    if (!std::strcmp(event.event, "release")) {
        for (size_t i = 0; i < profile.count; ++i) {
            auto& binding = profile.bindings[i];
            if (std::strcmp(binding.inputID, event.inputID) ||
                (std::strcmp(binding.event, "press") && std::strcmp(binding.event, "hold")) ||
                std::strcmp(binding.action.type, "openBuilds") ||
                std::strncmp(binding.action.text, "continuousJog", 13)) continue;
            if (binding.state.seen && static_cast<int32_t>(event.sequence - binding.state.sequence) <= 0)
                continue;
            bool hasCancel = false;
            for (size_t j = 0; j < profile.count; ++j) {
                const auto& release = profile.bindings[j];
                hasCancel = hasCancel || (!std::strcmp(release.inputID, event.inputID) &&
                    !std::strcmp(release.event, "release") &&
                    !std::strcmp(release.action.type, "openBuilds") &&
                    !std::strcmp(release.action.text, "cancelJog"));
            }
            if (!hasCancel) {
                NativeAction cancel = binding.action;
                std::strcpy(cancel.text, "cancelJog");
                if (dispatch(binding, cancel)) {
                    binding.state.sequence = event.sequence;
                    binding.state.seen = true;
                    binding.state.pressed = false;
                }
            }
        }
    }
}
template <typename Dispatch>
void releaseHardwareInputs(NativeProfile& profile, const BoardInfo& board, bool* pressed,
                           Dispatch dispatch) {
    for (size_t i = 0; i < board.inputCount; ++i) {
        if (!pressed[i]) continue;
        for (size_t j = 0; j < profile.count; ++j) {
            auto& binding = profile.bindings[j];
            if (std::strcmp(binding.inputID, board.inputs[i].id)) continue;
            if (!std::strcmp(binding.event, "release")) dispatch(binding, binding.action);
            if ((!std::strcmp(binding.event, "press") || !std::strcmp(binding.event, "hold")) &&
                !std::strcmp(binding.action.type, "openBuilds") &&
                !std::strncmp(binding.action.text, "continuousJog", 13)) {
                NativeAction cancel = binding.action;
                std::strcpy(cancel.text, "cancelJog");
                dispatch(binding, cancel);
            }
            binding.state.pressed = false;
        }
        pressed[i] = false;
    }
}
} // namespace paper_board
