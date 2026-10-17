#pragma once

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>

namespace paper_board {

struct Rect { double x, y, width, height; };
struct DisplayInfo {
    int width, height;
    bool touch;
    const char* pixelFormat;
    int rotation;
};
struct InputInfo {
    const char* id;
    const char* name;
    const char* kind;
    const char* events[3];
    Rect bounds;
    double minimum;
    double maximum;
};
struct BoardInfo {
    const char* id;
    const char* revision;
    const char* name;
    const char* manufacturer;
    const DisplayInfo* display;
    Rect bounds;
    Rect screen;
    const InputInfo* inputs;
    size_t inputCount;
    bool profile7;
    bool firmwareUpdate;
    size_t maxProfileBytes;
    size_t maxControls;
    size_t maxPages;
};
inline const BoardInfo& m5paper() {
    static const DisplayInfo display{540, 960, true, "gray4", 0};
    static const BoardInfo board{"m5stack.m5paper", "1.0", "M5Paper", "M5Stack",
        &display, {0, 0, 77, 132}, {4, 5, 69, 122}, nullptr, 0, false, true,
        256 * 1024, 24, 8};
    return board;
}
inline const BoardInfo& esp32Reference() {
    static const InputInfo inputs[] = {
        {"button-1", "Button 1", "button", {"press", "hold", "release"}, {16, 24, 64, 64}, 0, 0},
        {"encoder-1", "Encoder", "encoder", {"rotate", nullptr, nullptr}, {112, 24, 64, 64}, 0, 0},
        {"slider-1", "Slider", "slider", {"change", nullptr, nullptr}, {208, 24, 64, 112}, 0, 4095},
    };
    static const BoardInfo board{"paperremote.esp32-screenless-reference", "1", "ESP32 reference",
        "PaperGIF", nullptr, {0, 0, 320, 160}, {}, inputs, 3, true, false, 32768, 24, 8};
    return board;
}
inline const BoardInfo& superminiS3Mt6701() {
    static const InputInfo inputs[] = {
        {"button-1", "Button 1", "button", {"press", "hold", "release"}, {48, 88, 48, 48}, 0, 0},
        {"button-2", "Button 2", "button", {"press", "hold", "release"}, {224, 88, 48, 48}, 0, 0},
        {"dial-1", "MT6701 dial", "dial", {"change", nullptr, nullptr}, {112, 32, 96, 96}, 0, 16383},
    };
    static const BoardInfo board{"paperremote.supermini-s3-mt6701", "1",
        "ESP32-S3 SuperMini with MT6701", "PaperGIF", nullptr,
        {0, 0, 320, 160}, {}, inputs, 3, true, false, 32768, 24, 8};
    return board;
}
inline bool validRect(const Rect& r) {
    return std::isfinite(r.x) && std::isfinite(r.y) && std::isfinite(r.width) &&
        std::isfinite(r.height) && r.width > 0 && r.height > 0;
}
inline Rect fit(const Rect& source, const Rect& viewport) {
    if (!validRect(source) || !validRect(viewport)) return {};
    const double scale = std::fmin(viewport.width / source.width, viewport.height / source.height);
    return {viewport.x + (viewport.width - source.width * scale) / 2,
        viewport.y + (viewport.height - source.height * scale) / 2,
        source.width * scale, source.height * scale};
}
inline Rect project(const Rect& item, const Rect& source, const Rect& destination) {
    if (!validRect(source) || !validRect(destination) || !validRect(item)) return {};
    return {destination.x + (item.x - source.x) * destination.width / source.width,
        destination.y + (item.y - source.y) * destination.height / source.height,
        item.width * destination.width / source.width,
        item.height * destination.height / source.height};
}
inline bool contains(const Rect& r, double x, double y) {
    return validRect(r) && x >= r.x && y >= r.y && x < r.x + r.width && y < r.y + r.height;
}
struct InputEvent {
    const char* inputID;
    const char* event;
    double value;
    uint32_t sequence;
};
class DisplayDriver {
public:
    virtual ~DisplayDriver() = default;
    virtual const DisplayInfo* info() const = 0;
    virtual void begin() = 0;
    virtual void drawControl(const char* id, const Rect& pixels) = 0;
    virtual void present() = 0;
};
class InputDriver {
public:
    virtual ~InputDriver() = default;
    virtual void begin() = 0;
    virtual bool poll(InputEvent& event) = 0;
    virtual void release() = 0;
};
class BoardDriver {
public:
    virtual ~BoardDriver() = default;
    virtual const BoardInfo& info() const = 0;
    virtual DisplayDriver* display() = 0;
    virtual InputDriver* inputs() = 0;
    void begin() {
        if (display()) display()->begin();
        if (inputs()) inputs()->begin();
    }
};
inline const InputInfo* findInput(const BoardInfo& board, const char* id, const char* event) {
    for (size_t i = 0; i < board.inputCount; ++i) {
        if (std::strcmp(board.inputs[i].id, id)) continue;
        for (const char* supported : board.inputs[i].events)
            if (supported && std::strcmp(supported, event) == 0) return &board.inputs[i];
    }
    return nullptr;
}
inline bool compatibleFirmware(const BoardInfo& board, const char* id, const char* revision) {
    return id && revision && std::strcmp(id, board.id) == 0 &&
        std::strcmp(revision, board.revision) == 0;
}

} // namespace paper_board
