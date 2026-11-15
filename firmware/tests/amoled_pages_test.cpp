#include <cassert>
#include <cstdlib>
#include <fstream>
#include <vector>
#include "waveshare_page_view.h"
#include <src/misc/lv_timer_private.h>

using namespace paper_board;

void* heap_caps_calloc(size_t count, size_t size, uint32_t) { return std::calloc(count, size); }
void* heap_caps_malloc(size_t size, uint32_t) { return std::malloc(size); }
void heap_caps_free(void* pointer) { std::free(pointer); }

static WavesharePageView view;
static std::vector<uint16_t> pixels(368 * 448);
static lv_point_t point{};
static bool touching = false;
static int clicks = 0, changes = 0, pageChanges = 0;
static uint16_t* pendingPixels = nullptr;
static lv_area_t pendingArea{};
static std::vector<uint16_t> pendingCopy;
static bool transferComplete = false;
static uint16_t drawBuffers[2][368 * 448];
static unsigned bufferFlushes[2]{};
static size_t flushedPixels = 0;

static void completeTransfer() {
    if (!pendingPixels || transferComplete) return;
    assert(std::equal(pendingCopy.begin(), pendingCopy.end(), pendingPixels));
    auto* source = pendingPixels;
    const auto* area = &pendingArea;
    for (int row = area->y1; row <= area->y2; ++row)
        for (int column = area->x1; column <= area->x2; ++column)
            pixels[row * 368 + column] = *source++;
    transferComplete = true;
}
static void flush(lv_display_t*, const lv_area_t* area, uint8_t* data) {
    assert(!pendingPixels);
    assert(area->x1 >= 0 && area->y1 >= 0 && area->x2 < 368 && area->y2 < 448);
    pendingPixels = reinterpret_cast<uint16_t*>(data);
    pendingArea = *area;
    const size_t count = size_t(area->x2 - area->x1 + 1) * size_t(area->y2 - area->y1 + 1);
    flushedPixels += count;
    pendingCopy.assign(pendingPixels, pendingPixels + count);
    transferComplete = false;
    if (pendingPixels == drawBuffers[0]) ++bufferFlushes[0];
    else { assert(pendingPixels == drawBuffers[1]); ++bufferFlushes[1]; }
}
static void waitForTransfer(lv_display_t*) {
    assert(pendingPixels);
    completeTransfer();
    pendingPixels = nullptr;
}
static void capture(const char* path) {
    std::ofstream file(path, std::ios::binary);
    file << "P6\n368 448\n255\n";
    size_t lit = 0;
    for (const auto pixel : pixels) {
        const char rgb[] = {char(((pixel >> 11) & 31) * 255 / 31),
            char(((pixel >> 5) & 63) * 255 / 63), char((pixel & 31) * 255 / 31)};
        file.write(rgb, 3);
        if (pixel) ++lit;
    }
    assert(file && lit > 6000);
}
int main(int argc, char** argv) {
    MediaSynchronization synchronization;
    synchronization.pollAt = 2000;
    const auto subscriptionID = synchronization.subscriptionID(7, 1);
    for (uint32_t now = 1000; now < 2000; ++now) {
        synchronization.command(now);
        assert(synchronization.subscriptionID(7, 1) == subscriptionID);
        assert(synchronization.pollAt == 1350);
    }
    assert(!synchronization.acceptsPoll(0, 2000));
    assert(synchronization.acceptsPoll(synchronization.epoch, 2000));
    synchronization.updatedAt = 2100;
    assert(!synchronization.acceptsPoll(synchronization.epoch, 2099));
    assert(synchronization.acceptsPoll(synchronization.epoch, 2100));
    assert(synchronization.subscriptionID(8, 1) != subscriptionID);
    assert(synchronization.subscriptionID(7, 0) != subscriptionID);
    JsonDocument targets;
    assert(!deserializeJson(targets, R"({"computers":[{"id":"ABC"},{"id":"def"}]})"));
    assert(nativeComputerIndex(targets.as<JsonVariantConst>(), "") == 0);
    assert(nativeComputerIndex(targets.as<JsonVariantConst>(), "DEF") == 1);
    assert(nativeComputerIndex(targets.as<JsonVariantConst>(), "missing") == -2);
    targets.clear();
    assert(nativeComputerIndex(targets.as<JsonVariantConst>(), "") == -1);
    assert(nativeComputerIndex(targets.as<JsonVariantConst>(), "ABC") == -2);
    PageMediaState decoded;
    assert(!deserializeJson(targets, R"({"available":true,"elapsedMilliseconds":60000,
        "durationMilliseconds":240000,"playing":true,"text":"Track title"})"));
    assert(decoded.update(targets.as<JsonObjectConst>(), 1000));
    assert(decoded.timeline.available && media_timeline::elapsedAt(decoded.timeline, 2000) == 61000);
    targets["playing"] = false;
    assert(decoded.update(targets.as<JsonObjectConst>(), 2000));
    assert(media_timeline::elapsedAt(decoded.timeline, 3000) == 60000);
    targets["available"] = false;
    assert(decoded.update(targets.as<JsonObjectConst>(), 3000));
    assert(!decoded.timeline.available && !decoded.text[0]);
    assert(!deserializeJson(targets, R"({"available":true,"elapsedMilliseconds":60000,
        "durationMilliseconds":240000,"playing":true,"text":"Held track"})"));
    assert(decoded.update(targets.as<JsonObjectConst>(), 4000));
    const auto heldRevision = decoded.trackRevision;
    decoded.noteLocalSeek(4500);
    targets["available"] = false;
    assert(decoded.update(targets.as<JsonObjectConst>(), 5500));
    assert(decoded.timeline.available && !std::strcmp(decoded.text, "Held track"));
    assert(decoded.trackRevision == heldRevision && decoded.timeline.durationMilliseconds == 240000);
    targets["available"] = true;
    targets.remove("elapsedMilliseconds");
    targets.remove("durationMilliseconds");
    assert(decoded.update(targets.as<JsonObjectConst>(), 6000));
    assert(decoded.timeline.available && decoded.trackRevision == heldRevision);
    const uint8_t emptyPhone[] = {0x61, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0};
    assert(decoded.updatePhone(emptyPhone, sizeof(emptyPhone), 7000));
    assert(decoded.timeline.available && !std::strcmp(decoded.text, "Held track"));
    targets["available"] = false;
    assert(decoded.update(targets.as<JsonObjectConst>(), 4500 + 5000));
    assert(!decoded.timeline.available && !decoded.text[0]);
    const uint8_t phoneState[] = {0x61, 3, 128, 0x60, 0xea, 0, 0, 0x80, 0xa9, 3, 0, 5, 'P', 'h', 'o', 'n', 'e'};
    assert(decoded.updatePhone(phoneState, sizeof(phoneState), 1000));
    assert(decoded.timeline.durationMilliseconds == 240000 && !std::strcmp(decoded.text, "Phone"));
    assert(!decoded.updatePhone(phoneState, sizeof(phoneState) - 1, 2000));
    assert(decoded.timeline.sampledAt == 1000);
    assert(!deserializeJson(targets, R"({"items":[{"id":"media-2-1-4","available":true,
        "elapsedMilliseconds":4294967295,"durationMilliseconds":240000,"playing":true,"text":"Desktop"}]})"));
    assert(!decoded.updateItems(targets.as<JsonVariantConst>(), "media-1-1-4", 2000));
    assert(!decoded.updateItems(targets.as<JsonVariantConst>(), "media-2-2-4", 2000));
    assert(!decoded.updateItems(targets.as<JsonVariantConst>(), "media-2-1-3", 2000));
    assert(!std::strcmp(decoded.text, "Phone"));
    assert(decoded.updateItems(targets.as<JsonVariantConst>(), "media-2-1-4", 2000));
    assert(decoded.timeline.elapsedMilliseconds == 240000);
    targets["items"][0]["durationMilliseconds"] = uint64_t(UINT32_MAX) + 1;
    assert(decoded.updateItems(targets.as<JsonVariantConst>(), "media-2-1-4", 3000));
    assert(!decoded.timeline.available);
    lv_init();
    auto* display = lv_display_create(368, 448);
    lv_display_set_color_format(display, LV_COLOR_FORMAT_RGB565);
    lv_display_set_buffers(display, drawBuffers[0], drawBuffers[1], sizeof(drawBuffers[0]), LV_DISPLAY_RENDER_MODE_PARTIAL);
    lv_display_set_flush_cb(display, flush);
    lv_display_set_flush_wait_cb(display, waitForTransfer);
    assert(lv_display_get_refr_timer(display)->period == 16);
    auto* pointer = lv_indev_create();
    lv_indev_set_type(pointer, LV_INDEV_TYPE_POINTER);
    lv_timer_set_period(lv_indev_get_read_timer(pointer), 16);
    lv_indev_set_read_cb(pointer, [](lv_indev_t*, lv_indev_data_t* data) {
        view.touch(point.x, point.y, touching);
        data->point = point;
        data->state = touching ? LV_INDEV_STATE_PRESSED : LV_INDEV_STATE_RELEASED;
    });
    auto* screen = lv_screen_active();
    lv_obj_set_style_bg_color(screen, lv_color_black(), 0);
    lv_obj_set_style_text_color(screen, lv_color_white(), 0);
    lv_obj_set_scrollable(screen, false);
    view.begin(screen);
    JsonDocument json;
    assert(!deserializeJson(json, R"({"pages":[{"id":"music","name":"Music","gridColumns":2,"gridRows":4,"controls":[
      {"id":"play","title":"Play / Pause","symbol":"playpause.fill","kind":"button","layoutSlot":0,
       "action":{"type":"macMedia","host":"","text":"playPause","value":0,"modifiers":[]}},
      {"id":"next","title":"Next Track","symbol":"forward.end.fill","kind":"button","layoutSlot":1,
       "action":{"type":"macMedia","host":"","text":"next","value":0,"modifiers":[]}},
      {"id":"volume","title":"Volume","kind":"slider","layoutSlot":4,"gridWidth":2,
       "action":{"type":"macMedia","host":"","text":"volume","value":128,"modifiers":[]}}
    ]},{"id":"lights","name":"Lights","gridColumns":2,"gridRows":4,"controls":[
      {"id":"power","title":"Desk Light","symbol":"lightbulb.fill","kind":"button","layoutSlot":0,
       "action":{"type":"wledPower","host":"192.168.1.2","text":"toggle","value":0,"modifiers":[]}},
      {"id":"brightness","title":"Brightness","kind":"slider","layoutSlot":4,"gridWidth":2,
       "action":{"type":"wledBrightness","host":"192.168.1.2","text":"","value":200,"modifiers":[]}}
    ]}]})"));
    json["pages"][0]["controls"][2]["action"]["modifiers"].to<JsonArray>().add("shift");
    assert(validTouchPages(json));
    static WaveshareUiState state;
    state.configured = true;
    state.profile = &json;
    state.controlEvent = [](size_t index, const char* event, double value) {
        if (!std::strcmp(event, "activate")) { assert(index == 0); ++clicks; }
        if (!std::strcmp(event, "change")) { assert(index == 2 && value >= 0 && value <= 100); ++changes; }
        return true;
    };
    state.changePage = [](int delta) {
        pageChanges += delta;
        const int count = (*state.profile)["pages"].size();
        state.pageIndex = (int(state.pageIndex) + delta + count) % count;
    };
    auto tick = [&] {
        lv_tick_inc(20); state.now = lv_tick_get(); view.poll(state); completeTransfer();
    };
    auto input = [&](int x, int y, bool down) {
        point = {x, y}; touching = down; tick(); tick();
    };
    tick(); tick();
    auto* volumeWidget = lv_obj_get_child(lv_obj_get_child(lv_obj_get_child(screen, 0), 2), 2);
    auto* volumeSlider = lv_obj_get_child(volumeWidget, 0);
    assert(lv_obj_get_width(volumeSlider) == lv_obj_get_width(volumeWidget) - 2);
    assert(lv_obj_get_height(volumeSlider) == lv_obj_get_height(volumeWidget) - 2);
    assert(lv_obj_get_style_bg_opa(volumeSlider, LV_PART_KNOB) == LV_OPA_TRANSP);
    assert(lv_slider_get_orientation(volumeSlider) == LV_SLIDER_ORIENTATION_HORIZONTAL);
    lv_area_t volumeArea{};
    lv_obj_get_coords(volumeSlider, &volumeArea);
    assert(pixels[(volumeArea.y2 - 8) * 368 + volumeArea.x1 + 12] == uint16_t(0xEF5D));
    assert(pixels[(volumeArea.y2 - 8) * 368 + volumeArea.x2 - 12] == uint16_t(0x18C3));
    const int volumeWidth = lv_obj_get_width(volumeSlider);
    input(volumeArea.x1 + volumeWidth / 4, volumeArea.y1 + 12, true);
    input(volumeArea.x1 + volumeWidth * 3 / 4, volumeArea.y1 + 12, true);
    assert(lv_slider_get_value(volumeSlider) > 700 && lv_slider_get_value(volumeSlider) < 800);
    assert(changes > 0 && pageChanges == 0);
    assert(!std::strcmp(lv_label_get_text(lv_obj_get_child(volumeSlider, 2)),
        lv_label_get_text(lv_obj_get_child(lv_obj_get_child(volumeSlider, 1), 1))));
    input(volumeArea.x1 + volumeWidth * 3 / 4, volumeArea.y1 + 12, false);
    const int originalWidgetWidth = lv_obj_get_width(volumeWidget);
    for (int width : {80, 170, 350}) {
        lv_obj_set_width(volumeWidget, width + 2);
        lv_obj_set_width(volumeSlider, width);
        tick(); tick();
        lv_area_t edge;
        lv_obj_get_coords(volumeSlider, &edge);
        const int center = (edge.x1 + edge.x2) / 2;
        input(center, edge.y1 + 12, true);
        input(edge.x2, edge.y1 + 12, true);
        assert(lv_slider_get_value(volumeSlider) == 1000);
        input(edge.x2, edge.y1 + 12, false);
        input(center, edge.y1 + 12, true);
        input(edge.x1, edge.y1 + 12, true);
        assert(lv_slider_get_value(volumeSlider) == 0);
        input(edge.x1, edge.y1 + 12, false);
    }
    lv_obj_set_width(volumeWidget, originalWidgetWidth);
    lv_obj_set_width(volumeSlider, volumeWidth);
    tick(); tick();
    if (argc > 1) capture(argv[1]);
    const size_t beforePressPixels = flushedPixels;
    input(80, 100, true);
    const size_t pressPixels = flushedPixels - beforePressPixels;
    assert(clicks == 0);
    assert(pressPixels > 0 && pressPixels < pixels.size() / 4);
    std::printf("Button press redraw: %zu / %zu screen pixels\n", pressPixels, pixels.size());
    input(80, 100, false);
    assert(clicks == 1);
    const auto stationary = pixels;
    input(280, 12, true); input(220, 12, true);
    const auto firstDrag = pixels;
    input(180, 12, true);
    assert(pixels != firstDrag && pageChanges == 0);
    for (int row = 0; row < 448; ++row)
        for (int column = 0; column < 268; ++column)
            assert(pixels[row * 368 + column] == stationary[row * 368 + column + 100]);
    auto* incomingContent = lv_obj_get_child(lv_obj_get_child(screen, 1), 2);
    auto* incomingSlider = lv_obj_get_child(lv_obj_get_child(incomingContent, 1), 0);
    auto* incomingValue = lv_obj_get_child(incomingSlider, 2);
    assert(lv_obj_get_height(incomingSlider) > 80);
    assert(!std::strcmp(lv_label_get_text(incomingValue), "78%"));
    if (argc > 3) capture(argv[3]);
    input(280, 12, true); input(280, 12, false);
    for (int frame = 0; frame < 10; ++frame) tick();
    assert(pageChanges == 0 && clicks == 1 && pixels == stationary);
    input(280, 12, true); input(260, 12, true); input(260, 12, false);
    for (int frame = 0; frame < 10; ++frame) tick();
    assert(pageChanges == 0 && pixels == stationary);
    input(80, 312, true); input(260, 312, true); input(260, 312, false);
    assert(changes > 0 && pageChanges == 0 && clicks == 1);
    input(280, 100, true); input(100, 105, true); input(100, 105, false);
    assert(pageChanges == 0);
    const auto released = pixels;
    tick();
    assert(pixels != released && pageChanges == 0);
    input(80, 100, true); input(80, 100, false);
    for (int frame = 0; frame < 10; ++frame) tick();
    assert(pageChanges == 1 && state.pageIndex == 1 && clicks == 1);
    tick(); tick();
    if (argc > 2) capture(argv[2]);
    input(80, 12, true); input(240, 12, true); input(240, 12, false);
    for (int frame = 0; frame < 10; ++frame) tick();
    assert(pageChanges == 0 && state.pageIndex == 0 && clicks == 1);
    input(80, 12, true); input(240, 12, true); input(240, 12, false);
    for (int frame = 0; frame < 10; ++frame) tick();
    assert(pageChanges == -1 && state.pageIndex == 1);
    input(280, 12, true); input(100, 12, true); input(100, 12, false);
    for (int frame = 0; frame < 10; ++frame) tick();
    assert(pageChanges == 0 && state.pageIndex == 0);
    input(280, 12, true); input(100, 12, true); input(100, 12, false);
    ++state.profileRevision;
    for (int frame = 0; frame < 10; ++frame) tick();
    assert(pageChanges == 0 && state.pageIndex == 0);
    input(280, 12, true); input(100, 12, true);
    ++state.profileRevision;
    tick();
    input(100, 12, false);
    for (int frame = 0; frame < 10; ++frame) tick();
    assert(pageChanges == 0 && state.pageIndex == 0);
    for (int index = 0; index < 100; ++index) {
        state.pageIndex = index % 2;
        tick();
    }
    state.pageIndex = 0;
    tick();
    auto step = [&](int x, int y, bool down) {
        point = {x, y}; touching = down; tick();
    };
    step(200, 12, true);
    step(183, 12, true);
    step(166, 12, true);
    step(166, 12, false);
    for (int frame = 0; frame < 12 && pageChanges == 0; ++frame) tick();
    assert(pageChanges == 1 && state.pageIndex == 1);
    input(80, 12, true); input(240, 12, true); input(240, 12, false);
    for (int frame = 0; frame < 12; ++frame) tick();
    assert(pageChanges == 0 && state.pageIndex == 0);
    auto volumeControl = json["pages"][0]["controls"][2];
    volumeControl["action"]["type"] = "netHomeTemperature";
    volumeControl["action"]["valueTenths"] = 230;
    ++state.profileRevision;
    tick(); tick();
    lv_obj_t* temperaturePage = nullptr;
    for (int index = 0; index < int(lv_obj_get_child_count(screen)); ++index) {
        auto* child = lv_obj_get_child(screen, index);
        if (lv_obj_is_visible(child) && lv_obj_get_child_count(child) > 2) temperaturePage = child;
    }
    assert(temperaturePage);
    auto* temperatureSlider = lv_obj_get_child(lv_obj_get_child(lv_obj_get_child(temperaturePage, 2), 2), 0);
    assert(lv_slider_get_value(temperatureSlider) == 230);
    assert(lv_obj_get_width(lv_obj_get_child(temperatureSlider, 1)) == lv_obj_get_width(temperatureSlider) / 2);
    assert(!std::strcmp(lv_label_get_text(lv_obj_get_child(temperatureSlider, 2)), "23.0"));
    volumeControl["sliderOutlineInsetPixels"] = 8;
    ++state.profileRevision;
    tick(); tick();
    temperatureSlider = lv_obj_get_child(lv_obj_get_child(lv_obj_get_child(temperaturePage, 2), 2), 0);
    lv_area_t temperatureArea{};
    lv_obj_get_coords(temperatureSlider, &temperatureArea);
    assert(pixels[(temperatureArea.y2 - 12) * 368 + temperatureArea.x1 + 12] == uint16_t(0x18C3));
    assert(pixels[(temperatureArea.y1 + 3) * 368 + temperatureArea.x1 + 12] == uint16_t(0xEF5D));
    volumeControl.remove("sliderOutlineInsetPixels");
    volumeControl["action"]["type"] = "macMedia";
    json["pages"][0]["controls"][2]["action"]["text"] = "seek";
    static PageMediaState playback;
    playback.timeline = {true, true, false, 60000, 240000, state.now};
    std::strcpy(playback.text, "Example track - Example artist");
    state.mediaState = [](const NativeAction&) -> const PageMediaState* { return &playback; };
    ++state.profileRevision;
    tick(); tick();
    lv_obj_t* activePage = nullptr;
    for (int index = 0; index < int(lv_obj_get_child_count(screen)); ++index) {
        auto* child = lv_obj_get_child(screen, index);
        if (lv_obj_is_visible(child) && lv_obj_get_child_count(child) > 2) activePage = child;
    }
    assert(activePage);
    auto* seekWidget = lv_obj_get_child(lv_obj_get_child(activePage, 2), 2);
    auto* seekSlider = lv_obj_get_child(seekWidget, 0);
    assert(lv_obj_get_height(seekSlider) > 80);
    assert(lv_slider_get_value(seekSlider) >= 250 && lv_slider_get_value(seekSlider) < 260);
    assert(!std::strcmp(lv_label_get_text(lv_obj_get_child(activePage, 1)), "1:00 / 4:00"));
    if (argc > 5) capture(argv[5]);
    volumeControl["action"]["value"] = 204;
    tick();
    assert(lv_slider_get_value(seekSlider) == 800);
    assert(!std::strcmp(lv_label_get_text(lv_obj_get_child(activePage, 1)), "3:12 / 4:00"));
    playback.timeline.elapsedMilliseconds = 30000;
    playback.timeline.sampledAt = state.now;
    tick();
    assert(lv_slider_get_value(seekSlider) == 800);
    const int previousChanges = changes;
    input(100, 280, true); input(270, 280, true);
    assert(changes == previousChanges);
    const int draggedValue = lv_slider_get_value(seekSlider);
    playback.timeline.elapsedMilliseconds = 30000;
    tick();
    assert(lv_slider_get_value(seekSlider) == draggedValue);
    input(270, 280, false);
    assert(changes == previousChanges + 1);
    tick();
    assert(lv_slider_get_value(seekSlider) == draggedValue);
    playback.timeline.playing = false;
    playback.timeline.elapsedMilliseconds = uint64_t(playback.timeline.durationMilliseconds) * draggedValue / 1000;
    playback.timeline.sampledAt = state.now;
    for (int frame = 0; frame < 80; ++frame) tick();
    assert(lv_slider_get_value(seekSlider) == draggedValue);
    volumeControl["action"]["value"] = 255;
    tick();
    assert(lv_slider_get_value(seekSlider) == 1000);
    media_timeline::State endpoint = playback.timeline;
    endpoint.available = true;
    endpoint.playing = true;
    endpoint.stale = false;
    assert(media_timeline::seekFinishesTrack(endpoint, 255));
    assert(!media_timeline::seekFinishesTrack(endpoint, 254));
    endpoint.playing = false;
    assert(!media_timeline::seekFinishesTrack(endpoint, 255));
    endpoint.playing = true;
    endpoint.stale = true;
    assert(!media_timeline::seekFinishesTrack(endpoint, 255));
    endpoint.stale = false;
    endpoint.durationMilliseconds = 0;
    assert(!media_timeline::seekFinishesTrack(endpoint, 255));
    endpoint.durationMilliseconds = 240000;
    NativeProfile endpointProfile;
    endpointProfile.count = 1;
    auto& endpointBinding = endpointProfile.bindings[0];
    std::strcpy(endpointBinding.inputID, "dial-1");
    std::strcpy(endpointBinding.event, "change");
    std::strcpy(endpointBinding.action.type, "macMedia");
    std::strcpy(endpointBinding.action.text, "seek");
    endpointBinding.state.mode = BindingMode::absolute;
    endpointBinding.state.value = 99;
    int finishCommands = 0;
    for (uint32_t serial = 1; serial <= 10; ++serial)
        dispatchHardwareInput(endpointProfile, waveshareAmoled18V2(),
            {"dial-1", "change", 163.83, serial, true},
            [&](const HardwareBinding&, const NativeAction& action) {
                assert(media_timeline::seekFinishesTrack(endpoint, action.value));
                ++finishCommands;
                return true;
            });
    assert(finishCommands == 1);
    HardwareBinding seekBinding;
    seekBinding.state.mode = BindingMode::absolute;
    seekBinding.state.value = 100;
    seekBinding.hasLocalValue = true;
    seekBinding.localValueAt = state.now;
    seekBinding.mediaTrackRevision = playback.trackRevision;
    assert(!rebaseSeekBinding(seekBinding, playback, state.now));
    JsonDocument nextTrack;
    nextTrack["available"] = true;
    nextTrack["playing"] = false;
    nextTrack["text"] = "Next track - Next artist";
    nextTrack["elapsedMilliseconds"] = 2000;
    nextTrack["durationMilliseconds"] = 180000;
    assert(playback.update(nextTrack.as<JsonObjectConst>(), state.now + 1));
    tick();
    assert(lv_slider_get_value(seekSlider) == 11);
    assert(!std::strcmp(lv_label_get_text(lv_obj_get_child(activePage, 1)), "0:02 / 3:00"));
    assert(rebaseSeekBinding(seekBinding, playback, state.now));
    assert(seekBinding.state.value == 1);
    double nextSeek = 0;
    assert(applyInput(seekBinding.state, waveshareAmoled18V2().inputs[2],
        {"dial-1", "change", 163.83, 1, true}, nextSeek));
    assert(nextSeek == 2);
    const uint32_t trackRevision = playback.trackRevision;
    nextTrack["elapsedMilliseconds"] = 3000;
    assert(playback.update(nextTrack.as<JsonObjectConst>(), state.now + 1));
    assert(playback.trackRevision == trackRevision);
    assert(!rebaseSeekBinding(seekBinding, playback, state.now + 1));
    playback.timeline.available = false;
    tick();
    input(100, 280, true); input(270, 280, true); input(270, 280, false);
    assert(changes == previousChanges + 1);
    playback.timeline.available = true;
    lv_area_t seekArea{};
    lv_obj_get_coords(seekSlider, &seekArea);
    const int edgeY = seekArea.y1 - 14;
    assert(edgeY > 16);
    const int pagesBeforeEdge = pageChanges;
    const int changesBeforeEdge = changes;
    const int beforeEdge = lv_slider_get_value(seekSlider);
    input(seekArea.x1 + 20, edgeY, true);
    input(seekArea.x1 + 80, edgeY, true);
    assert(pageChanges == pagesBeforeEdge);
    const int edgeValue = lv_slider_get_value(seekSlider);
    assert(edgeValue > beforeEdge);
    playback.timeline.playing = true;
    playback.timeline.elapsedMilliseconds = 1000;
    playback.timeline.sampledAt = state.now;
    tick();
    assert(lv_slider_get_value(seekSlider) == edgeValue);
    input(seekArea.x1 + 80, edgeY, false);
    assert(changes == changesBeforeEdge + 1);
    view.setPointer([](int& x, int& y) { x = point.x; y = point.y; return touching; });
    const int heldBefore = changes;
    input(seekArea.x1 + 30, seekArea.y1 + 8, true);
    const int heldValue = lv_slider_get_value(seekSlider);
    playback.timeline.elapsedMilliseconds = playback.timeline.durationMilliseconds - 1000;
    playback.timeline.sampledAt = state.now;
    tick();
    assert(pageChanges == pagesBeforeEdge);
    assert(lv_slider_get_value(seekSlider) == heldValue);
    input(seekArea.x1 + 30, seekArea.y1 + 8, false);
    assert(changes == heldBefore + 1);
    view.setPointer(nullptr);
    const int scrubbed = lv_slider_get_value(seekSlider);
    const auto* clockBeforeEmpty = lv_label_get_text(lv_obj_get_child(activePage, 1));
    assert(clockBeforeEmpty[0]);
    char clockBeforeCopy[40];
    std::snprintf(clockBeforeCopy, sizeof(clockBeforeCopy), "%s", clockBeforeEmpty);
    playback.noteLocalSeek(state.now);
    JsonDocument emptyNowPlaying;
    emptyNowPlaying["available"] = false;
    const auto revisionBeforeEmpty = playback.trackRevision;
    assert(playback.update(emptyNowPlaying.as<JsonObjectConst>(), state.now + 1000));
    assert(playback.timeline.available && playback.trackRevision == revisionBeforeEmpty);
    for (int frame = 0; frame < 50; ++frame) tick();
    assert(lv_slider_get_value(seekSlider) == scrubbed);
    assert(!std::strcmp(lv_label_get_text(lv_obj_get_child(activePage, 1)), clockBeforeCopy));
    bool keptTitle = false;
    for (uint32_t child = 0; child < lv_obj_get_child_count(seekSlider); ++child) {
        auto* item = lv_obj_get_child(seekSlider, child);
        keptTitle = keptTitle || (lv_obj_check_type(item, &lv_label_class) &&
            !std::strcmp(lv_label_get_text(item), playback.text));
    }
    assert(keptTitle);
    auto seekControl = json["pages"][0]["controls"][2];
    seekControl["sliderOutlineInsetPixels"] = 8;
    seekControl["textBox"]["horizontalAlignment"] = "center";
    seekControl["textBox"]["verticalAlignment"] = "center";
    ++state.profileRevision;
    tick(); tick();
    if (argc > 5) capture((std::string(argv[5]) + ".outline.ppm").c_str());
    state.mediaState = nullptr;
    json["pages"][0]["controls"][2]["action"]["text"] = "volume";
    const auto beforeBackground = pixels;
    state.buttonImage = [](const char* id) -> remote_button_texture::ImageView {
        assert(!std::strcmp(id, "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"));
        static const uint8_t samples[] = {0, 85, 170, 255};
        return {samples, 2, 2};
    };
    auto background = json["pages"][0]["controls"][0]["buttonTexture"].to<JsonObject>();
    background["kind"] = "image";
    background["imageID"] = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE";
    ++state.profileRevision;
    tick(); tick();
    assert(pixels != beforeBackground);
    if (argc > 6) capture(argv[6]);
    state.buttonImage = [](const char*) -> remote_button_texture::ImageView {
        static const uint8_t red[] = {0, 248, 0, 248, 0, 248, 0, 248};
        return {red, 2, 2, true};
    };
    background["preserveColor"] = true;
    background["fade"] = 0;
    json["pages"][0]["controls"][0]["tintHex"] = "0000FF";
    json["pages"][0]["controls"][0]["backgroundTintHex"] = "00FF00";
    ++state.profileRevision;
    tick(); tick();
    assert(std::count(pixels.begin(), pixels.end(), uint16_t(0xF800)) > 500);
    assert(std::count(pixels.begin(), pixels.end(), uint16_t(0x001F)) > 20);
    if (argc > 6) capture((std::string(argv[6]) + ".color.ppm").c_str());
    background["kind"] = "none";
    ++state.profileRevision;
    tick(); tick();
    assert(std::count(pixels.begin(), pixels.end(), uint16_t(0x07E0)) > 500);
    json["pages"][0]["controls"][0].remove("tintHex");
    json["pages"][0]["controls"][0].remove("backgroundTintHex");
    background["fade"] = 50;
    background["preserveColor"] = false;
    const auto imageBackground = pixels;
    background["kind"] = "pattern";
    background["pattern"] = "hexagons";
    ++state.profileRevision;
    tick(); tick();
    assert(pixels != imageBackground);
    if (argc > 7) capture(argv[7]);
    JsonDocument dense;
    auto densePages = dense["pages"].to<JsonArray>();
    for (int pageNumber = 0; pageNumber < 2; ++pageNumber) {
        auto page = densePages.add<JsonObject>();
        page["id"] = pageNumber ? "dense2" : "dense1";
        page["name"] = pageNumber ? "Dense Two" : "Dense One";
        page["gridColumns"] = 3;
        page["gridRows"] = 8;
        auto controls = page["controls"].to<JsonArray>();
        for (size_t index = 0; index < maxPageTiles; ++index) {
            auto control = controls.add<JsonObject>();
            char identifier[24];
            std::snprintf(identifier, sizeof(identifier), "slider%u", unsigned(index));
            control["id"] = identifier;
            control["title"] = "Level";
            control["kind"] = "slider";
            control["gridWidth"] = 1;
            control["gridHeight"] = 1;
            control["action"].set(json["pages"][0]["controls"][2]["action"]);
        }
    }
    assert(validTouchPages(dense));
    state.profile = &dense;
    state.pageIndex = 0;
    ++state.profileRevision;
    tick(); tick();
    input(280, 12, true); input(180, 12, true);
    if (argc > 4) capture(argv[4]);
    input(180, 12, false);
    for (int frame = 0; frame < 10; ++frame) tick();
    assert(state.pageIndex == 1 && pageChanges == 1);
    lv_mem_monitor_t before{};
    static uint16_t saverPixels[368 * 448];
    std::fill(std::begin(saverPixels), std::end(saverPixels), uint16_t(0xf800));
    state.screenImage = reinterpret_cast<uint8_t*>(saverPixels);
    state.screensaver = true;
    tick(); tick();
    assert(std::all_of(pixels.begin(), pixels.end(), [](uint16_t pixel) { return pixel == 0xf800; }));
    const int changesBeforeWake = changes;
    input(100, 100, true);
    state.screensaver = false;
    tick();
    input(100, 100, false);
    assert(changes == changesBeforeWake);
    state.screenImage = nullptr;
    tick();
    lv_mem_monitor(&before);
    for (int index = 0; index < 100; ++index) {
        if (index % 2 == 0) ++state.profileRevision;
        state.pageIndex = index % 2;
        tick();
    }
    tick(); tick();
    lv_mem_monitor_t after{};
    lv_mem_monitor(&after);
    std::fprintf(stderr, "LVGL rebuild memory: before %zu bytes, after %zu bytes\n", before.free_size, after.free_size);
    // Rebuilding the cached neighbor after the loop can leave a few hundred bytes
    // of allocator overhead. A leaked page of tiles would be far larger.
    assert(after.free_size + 512 >= before.free_size);
    assert(bufferFlushes[0] > 100 && bufferFlushes[1] > 100);
    std::printf("AMOLED rendered drag, settle, cancellation, interruption, slider isolation and dense pages passed; LVGL free %zu bytes\n",
        after.free_size);
}