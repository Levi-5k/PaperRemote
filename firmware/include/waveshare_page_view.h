#pragma once

#include <lvgl.h>
#include <src/misc/cache/instance/lv_image_cache.h>
#include <esp_heap_caps.h>
#include "reference_pages.h"
#include "remote_icon_raster.h"
#include "remote_button_style.h"

namespace paper_board {
class WavesharePageView {
    struct Tile {
        WavesharePageView* owner = nullptr;
        size_t index = 0;
        lv_obj_t* widget = nullptr;
        lv_obj_t* slider = nullptr;
        lv_obj_t* valueLabel = nullptr;
        lv_obj_t* titleLabel = nullptr;
        lv_obj_t* filledText = nullptr;
        lv_obj_t* filledTitle = nullptr;
        lv_obj_t* filledValue = nullptr;
        lv_image_dsc_t icon{};
        uint8_t* pixels = nullptr;
        lv_image_dsc_t background{};
        uint16_t* backgroundPixels = nullptr;
        lv_obj_t* backgroundObject = nullptr;
        bool jog = false;
        bool down = false;
        bool temperature = false;
        bool brightness = false;
        bool seek = false;
        bool seekAvailable = false;
        bool textLaidOut = false;
        bool pendingSeek = false;
        uint32_t seekAt = 0;
        int seekValue = 0;
        int32_t seekActionValue = 0;
        uint32_t seekTrackRevision = 0;
        size_t pageIndex = SIZE_MAX;
    };
    struct Page {
        lv_obj_t* root = nullptr;
        lv_obj_t* header = nullptr;
        lv_obj_t* clock = nullptr;
        lv_obj_t* content = nullptr;
        Tile tiles[maxPageTiles];
        size_t index = SIZE_MAX;
        uint32_t revision = UINT32_MAX;
        bool showsClock = false;
        bool labelsReady = false;
    } pages[3];
    Page* visible = &pages[0];
    Page* neighbor = &pages[1];
    WaveshareUiState current;
    NativeAction pollAction;
    uint32_t revision = UINT32_MAX;
    size_t pageIndex = SIZE_MAX;
    PageSwipe swipe;
    int pendingPage = 0;
    int offset = 0;
    int direction = 0;
    int requestedDirection = 0;
    int swipeVelocity = 0;
    int swipeMoves = 0;
    int swipeSampleX = 0;
    uint32_t swipeSampleAt = 0;
    bool settling = false;
    bool (*readPointer)(int& x, int& y) = nullptr;
    bool applyingFinger = false;
    bool ignoreTouch = false;
    bool wakeTouch = false;
    uint32_t imageRevision = UINT32_MAX;
    lv_obj_t* saver = nullptr;
    lv_image_dsc_t saverImage{};

    static void setText(lv_obj_t* label, const char* text) {
        if (label && std::strcmp(lv_label_get_text(label), text)) lv_label_set_text(label, text);
    }
    static void onTile(lv_event_t* event) {
        auto* tile = static_cast<Tile*>(lv_event_get_user_data(event));
        if (!tile || !tile->owner) return;
        auto& owner = *tile->owner;
        if (!owner.current.controlEvent) return;
        const auto code = lv_event_get_code(event);
        if (tile->slider && !owner.applyingFinger && (code == LV_EVENT_VALUE_CHANGED || code == LV_EVENT_RELEASED)) {
            auto* pointer = lv_indev_active();
            if (pointer && lv_indev_get_type(pointer) == LV_INDEV_TYPE_POINTER) {
                lv_point_t point;
                lv_indev_get_point(pointer, &point);
                lv_area_t area;
                lv_obj_get_coords(tile->slider, &area);
                const int span = area.x2 - area.x1;
                if (span > 0) {
                    const int minimum = lv_slider_get_min_value(tile->slider);
                    const int range = lv_slider_get_max_value(tile->slider) - minimum;
                    const int position = std::clamp(int(point.x - area.x1), 0, span);
                    lv_slider_set_value(tile->slider, minimum + int((int64_t(position) * range + span / 2) / span), LV_ANIM_OFF);
                }
            }
        }
        if (tile->backgroundObject && (code == LV_EVENT_PRESSED || code == LV_EVENT_RELEASED || code == LV_EVENT_PRESS_LOST))
            lv_obj_set_hidden(tile->backgroundObject, code == LV_EVENT_PRESSED);
        const bool blocked = owner.swipe.swiped || owner.settling || owner.pendingPage ||
            owner.ignoreTouch || owner.wakeTouch || owner.current.screensaver ||
            tile->pageIndex != owner.pageIndex || (tile->seek && !tile->seekAvailable);
        if (tile->seek) {
            if (code == LV_EVENT_PRESSED) tile->down = !blocked;
            else if (code == LV_EVENT_RELEASED && tile->down) {
                tile->down = false;
                if (!blocked && owner.current.controlEvent(tile->index, "change", lv_slider_get_value(tile->slider) / 10.0)) {
                    tile->pendingSeek = true;
                    tile->seekAt = owner.current.now;
                    tile->seekValue = lv_slider_get_value(tile->slider);
                }
            } else if (code == LV_EVENT_PRESS_LOST) tile->down = false;
        } else if (tile->jog) {
            if (code == LV_EVENT_PRESSED && !blocked)
                tile->down = owner.current.controlEvent(tile->index, "press", 0);
            else if ((code == LV_EVENT_RELEASED || code == LV_EVENT_PRESS_LOST) && tile->down) {
                owner.current.controlEvent(tile->index, "release", 0);
                tile->down = false;
            }
        } else if (!blocked && code == LV_EVENT_CLICKED && !tile->slider) {
            owner.current.controlEvent(tile->index, "activate", 0);
        } else if (!blocked && code == LV_EVENT_VALUE_CHANGED && tile->slider) {
            owner.current.controlEvent(tile->index, "change", lv_slider_get_value(tile->slider) / 10.0);
        }
    }
    void release(Page& page) {
        for (auto& tile : page.tiles) {
            if (tile.jog && tile.down && current.controlEvent) current.controlEvent(tile.index, "release", 0);
            tile.down = false;
        }
    }
    Tile* sliderAt(int x, int y) {
        Tile* found = nullptr;
        for (auto& tile : visible->tiles) {
            if (!tile.slider) continue;
            lv_area_t area;
            lv_obj_get_coords(tile.widget ? tile.widget : tile.slider, &area);
            if (x >= area.x1 - 16 && x <= area.x2 + 16 && y >= area.y1 - 16 && y <= area.y2 + 16)
                found = &tile;
        }
        return found;
    }
    void placeSeek(Tile& tile, int x) {
        if (!tile.seek || !tile.seekAvailable || !tile.slider) return;
        lv_area_t area;
        lv_obj_get_coords(tile.slider, &area);
        const int span = area.x2 - area.x1;
        if (span <= 0) return;
        const int minimum = lv_slider_get_min_value(tile.slider);
        const int range = lv_slider_get_max_value(tile.slider) - minimum;
        const int position = std::clamp(int(x - area.x1), 0, span);
        applyingFinger = true;
        lv_slider_set_value(tile.slider, minimum + int((int64_t(position) * range + span / 2) / span), LV_ANIM_OFF);
        applyingFinger = false;
        tile.down = true;
    }
    void holdSeek(int x) {
        Tile* held = nullptr;
        for (auto& tile : visible->tiles) if (tile.seek && tile.down) held = &tile;
        if (!held) {
            held = sliderAt(swipe.startX, swipe.startY);
            if (held && !held->seek) held = nullptr;
        }
        if (held) placeSeek(*held, x);
    }
    void finishSeek(int x) {
        for (auto& tile : visible->tiles) {
            if (!tile.seek || !tile.down) continue;
            placeSeek(tile, x);
            tile.down = false;
            if (!tile.seekAvailable || !current.controlEvent) continue;
            if (current.controlEvent(tile.index, "change", lv_slider_get_value(tile.slider) / 10.0)) {
                tile.pendingSeek = true;
                tile.seekAt = current.now;
                tile.seekValue = lv_slider_get_value(tile.slider);
            }
        }
    }
    static void layoutSeekText(Tile& tile, JsonObjectConst control, const char* text) {
        if (tile.textLaidOut && !std::strcmp(lv_label_get_text(tile.titleLabel), text)) return;
        tile.textLaidOut = true;
        const int width = std::max(1, int(lv_obj_get_width(tile.slider)) - 14);
        const int height = std::max(1, int(lv_obj_get_height(tile.slider)) - 14);
        const char* size = control["textBox"]["textSize"] | "autoFit";
        const char* horizontal = control["textBox"]["horizontalAlignment"] | "leading";
        const char* vertical = control["textBox"]["verticalAlignment"] | "top";
        const lv_font_t* fonts[] = {&lv_font_montserrat_14, &lv_font_montserrat_20, &lv_font_montserrat_28};
        int choice = !std::strcmp(size, "small") ? 0 : !std::strcmp(size, "medium") ? 1 : 2;
        lv_point_t measured{};
        for (;;) {
            lv_text_get_size(&measured, text, fonts[choice], 0, 0, width, LV_TEXT_FLAG_NONE);
            if (std::strcmp(size, "autoFit") || measured.y <= height || !choice) break;
            --choice;
        }
        const int textHeight = std::min(height, int(measured.y));
        const int top = !std::strcmp(vertical, "center") ? (height - textHeight) / 2 :
            !std::strcmp(vertical, "bottom") ? height - textHeight : 0;
        const auto alignment = !std::strcmp(horizontal, "center") ? LV_TEXT_ALIGN_CENTER :
            !std::strcmp(horizontal, "trailing") ? LV_TEXT_ALIGN_RIGHT : LV_TEXT_ALIGN_LEFT;
        for (auto* label : {tile.titleLabel, tile.filledTitle}) {
            lv_obj_set_style_text_font(label, fonts[choice], 0);
            lv_obj_set_style_text_align(label, alignment, 0);
            lv_obj_set_size(label, width, std::max(1, textHeight));
            lv_obj_set_pos(label, 7, 7 + top);
            setText(label, text);
        }
    }
    void clear(Page& page) {
        release(page);
        lv_obj_clean(page.content);
        for (auto& tile : page.tiles) {
            if (tile.backgroundPixels) {
                lv_image_cache_drop(&tile.background);
                heap_caps_free(tile.backgroundPixels);
            }
            if (tile.pixels) {
                lv_image_cache_drop(&tile.icon);
                heap_caps_free(tile.pixels);
            }
            tile = Tile{};
        }
    }
    void addIcon(Tile& tile, const char* name, int side) {
        const auto* glyph = remote_icons::findGlyph(name);
        if (!glyph || side < 12) return;
        tile.pixels = static_cast<uint8_t*>(heap_caps_calloc(side * side, 1, MALLOC_CAP_SPIRAM));
        if (!tile.pixels) return;
        remote_icons::rasterize(*glyph, side, [&](int x, int y, uint8_t coverage) {
            tile.pixels[y * side + x] = coverage;
        });
        tile.icon.header.magic = LV_IMAGE_HEADER_MAGIC;
        tile.icon.header.cf = LV_COLOR_FORMAT_A8;
        tile.icon.header.w = side;
        tile.icon.header.h = side;
        tile.icon.header.stride = side;
        tile.icon.data_size = side * side;
        tile.icon.data = tile.pixels;
        auto* image = lv_image_create(tile.widget);
        lv_image_set_src(image, &tile.icon);
        lv_obj_set_style_image_recolor(image, lv_obj_get_style_text_color(tile.widget, LV_PART_MAIN), 0);
        lv_obj_set_style_image_recolor_opa(image, LV_OPA_COVER, 0);
        lv_obj_align(image, LV_ALIGN_TOP_MID, 0, 8);
    }
    void addBackground(Tile& tile, JsonObjectConst control, int width, int height) {
        const auto style = remote_button_style::colors(remote_button_style::resolve(
            (*current.profile)["buttonBackground"] | "outline", control["buttonBackground"] | ""), false);
        const uint8_t fill = remote_button_texture::luminance565(style.fill);
        const uint8_t foreground = remote_button_texture::luminance565(style.foreground);
        const uint32_t backgroundRGB = remote_button_texture::parseRGB(control["backgroundTintHex"] | "", uint32_t(fill) * 0x010101);
        const char* tint = control["tintHex"] | "202020";
        const uint32_t foregroundRGB = std::strcmp(tint, "202020")
            ? remote_button_texture::parseRGB(tint, uint32_t(foreground) * 0x010101) : uint32_t(foreground) * 0x010101;
        lv_obj_set_style_bg_color(tile.widget, lv_color_hex(backgroundRGB), 0);
        lv_obj_set_style_text_color(tile.widget, lv_color_hex(foregroundRGB), 0);
        const uint32_t pressedRGB = control["backgroundTintHex"].is<const char*>()
            ? remote_button_texture::blendRGB(backgroundRGB, foregroundRGB, 48) : (foreground < 128 ? 0xD0D0D0 : 0x303030);
        lv_obj_set_style_bg_color(tile.widget, lv_color_hex(pressedRGB), LV_STATE_PRESSED);
        lv_obj_set_style_border_width(tile.widget, style.border ? 1 : 0, 0);
        lv_obj_set_style_clip_corner(tile.widget, true, 0);
        JsonObjectConst json = control["buttonTexture"].is<JsonObjectConst>()
            ? control["buttonTexture"].as<JsonObjectConst>() : (*current.profile)["buttonTexture"].as<JsonObjectConst>();
        remote_button_texture::Texture texture;
        remote_button_texture::parseKind(json["kind"] | "none", texture.kind);
        if (texture.kind == remote_button_texture::Kind::none) return;
        remote_button_texture::parsePattern(json["pattern"] | "hexagons", texture.pattern);
        remote_button_texture::parseMode(json["mode"] | "monochrome", texture.mode);
        texture.scale = std::clamp(json["scale"] | 16, 6, 64);
        texture.lineWidth = std::clamp(json["lineWidth"] | 1, 1, 8);
        texture.fade = std::clamp(json["fade"] | 50, 0, 90);
        texture.preserveColor = json["preserveColor"] | false;
        texture.threshold = std::clamp(json["threshold"] | 128, 0, 255);
        texture.levels = std::clamp(json["monochromeLevels"] | 16, 0, 16);
        texture.dotSpacing = std::clamp(json["halftoneDotSpacing"] | 8, 3, 24);
        texture.angle = std::clamp(json["halftoneAngle"] | 45, 0, 90);
        texture.dotGain = std::clamp(json["halftoneDotGain"] | 0, -50, 50);
        remote_button_texture::ImageView image;
        if (texture.kind == remote_button_texture::Kind::image && current.buttonImage)
            image = current.buttonImage(json["imageID"] | "");
        remote_button_texture::Renderer renderer(texture, image, 255, 0, width, height, 6);
        if (!renderer.drawable()) return;
        tile.backgroundPixels = static_cast<uint16_t*>(heap_caps_malloc(size_t(width) * height * 2,
            MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
        if (!tile.backgroundPixels) return;
        for (int row = 0; row < height; ++row) for (int column = 0; column < width; ++column) {
            tile.backgroundPixels[row * width + column] = remote_button_texture::colorPixel(renderer, column, row,
                backgroundRGB, foregroundRGB, remote_button_texture::parseRGB(control["imageTintHex"] | "", foregroundRGB),
                control["imageTintHex"].is<const char*>());
        }
        tile.background.header.magic = LV_IMAGE_HEADER_MAGIC;
        tile.background.header.cf = LV_COLOR_FORMAT_RGB565;
        tile.background.header.w = width;
        tile.background.header.h = height;
        tile.background.header.stride = width * 2;
        tile.background.data_size = width * height * 2;
        tile.background.data = reinterpret_cast<uint8_t*>(tile.backgroundPixels);
        tile.backgroundObject = lv_image_create(tile.widget);
        lv_obj_set_clickable(tile.backgroundObject, false);
        lv_image_set_src(tile.backgroundObject, &tile.background);
    }
    void build(Page& surface, size_t indexToBuild) {
        clear(surface);
        surface.labelsReady = false;
        surface.revision = current.profileRevision;
        surface.index = indexToBuild;
        auto* header = surface.header;
        auto* content = surface.content;
        if (!current.profile) return;
        JsonObjectConst page = (*current.profile)["pages"][indexToBuild];
        setText(header, page.isNull() ? "OP Remote" : page["name"] | "Page");
        if (page.isNull() || page["controls"].size() == 0) {
            auto* label = lv_label_create(content);
            lv_label_set_text(label, current.configured ? "No controls" : "Waiting for profile");
            lv_obj_set_style_text_color(label, lv_color_hex(0x8E8E93), 0);
            lv_obj_center(label);
            return;
        }
        PageTilePlacement placements[maxPageTiles];
        if (!layoutPageTiles(page, placements)) return;
        const int columns = page["gridColumns"] | 2;
        const int rows = page["gridRows"] | 8;
        size_t index = 0;
        for (JsonObjectConst control : page["controls"].as<JsonArrayConst>()) {
            auto& tile = surface.tiles[index];
            tile.owner = this;
            tile.index = index;
            tile.pageIndex = indexToBuild;
            const auto frame = pageTileRect(placements[index++], columns, rows, 368, 448);
            const bool slider = !std::strcmp(control["kind"] | "", "slider");
            const bool text = !std::strcmp(control["kind"] | "", "textBox");
            tile.widget = text || slider ? lv_obj_create(content) : lv_button_create(content);
            lv_obj_remove_style_all(tile.widget);
            lv_obj_set_pos(tile.widget, int(frame.x), int(frame.y) - pageHeaderHeight);
            lv_obj_set_size(tile.widget, int(frame.width), int(frame.height));
            lv_obj_set_scrollable(tile.widget, false);
            lv_obj_set_style_radius(tile.widget, 6, 0);
            lv_obj_set_style_bg_color(tile.widget, lv_color_hex(0x181818), 0);
            lv_obj_set_style_bg_opa(tile.widget, LV_OPA_COVER, 0);
            lv_obj_set_style_bg_color(tile.widget, lv_color_hex(0x404040), LV_STATE_PRESSED);
            lv_obj_set_style_border_width(tile.widget, text ? 0 : 1, 0);
            lv_obj_set_style_border_color(tile.widget, lv_color_hex(0x777777), 0);
            lv_obj_set_style_text_color(tile.widget, lv_color_hex(0xF2F2F2), 0);
            if (!text && !slider) addBackground(tile, control, int(frame.width), int(frame.height));
            auto* title = lv_label_create(tile.widget);
            tile.titleLabel = title;
            lv_obj_set_width(title, std::max(1, int(frame.width) - 12));
            lv_label_set_long_mode(title, LV_LABEL_LONG_WRAP);
            lv_obj_set_style_text_align(title, LV_TEXT_ALIGN_CENTER, 0);
            lv_label_set_text(title, text ? control["textBox"]["sourceText"] | "" : control["title"] | "");
            if (slider) {
                NativeAction action;
                if (!parseAction(control["action"], action)) continue;
                const auto range = tileSliderState(action);
                tile.temperature = !std::strcmp(action.type, "netHomeTemperature");
                tile.brightness = !std::strcmp(action.type, "wledBrightness");
                tile.seek = (!std::strcmp(action.type, "macMedia") || !std::strcmp(action.type, "iPhoneMedia")) &&
                    !std::strcmp(action.text, "seek");
                tile.seekActionValue = action.value;
                {
                    tile.slider = lv_slider_create(tile.widget);
                    lv_obj_remove_style_all(tile.slider);
                    lv_obj_set_pos(tile.slider, 1, 1);
                    lv_obj_set_size(tile.slider, int(frame.width) - 2, int(frame.height) - 2);
                    lv_slider_set_orientation(tile.slider, LV_SLIDER_ORIENTATION_HORIZONTAL);
                    lv_slider_set_range(tile.slider, int(range.minimum * 10), int(range.maximum * 10));
                    lv_slider_set_value(tile.slider, int(range.value * 10), LV_ANIM_OFF);
                    lv_obj_set_style_radius(tile.slider, 5, LV_PART_MAIN);
                    lv_obj_set_style_radius(tile.slider, 5, LV_PART_INDICATOR);
                    lv_obj_set_style_bg_color(tile.slider, lv_color_hex(0x181818), LV_PART_MAIN);
                    lv_obj_set_style_bg_opa(tile.slider, LV_OPA_COVER, LV_PART_MAIN);
                    lv_obj_set_style_bg_color(tile.slider, lv_color_hex(0xE8E8E8), LV_PART_INDICATOR);
                    lv_obj_set_style_bg_opa(tile.slider, LV_OPA_COVER, LV_PART_INDICATOR);
                    const int outline = std::clamp(control["sliderOutlineInsetPixels"] | 0, 0,
                        std::max(0, std::min(32, int(std::min(frame.width, frame.height)) / 2 - 2)));
                    if (outline) {
                        auto* center = lv_obj_create(tile.slider);
                        lv_obj_remove_style_all(center);
                        lv_obj_set_pos(center, outline - 1, outline - 1);
                        lv_obj_set_size(center, int(frame.width) - 2 * outline, int(frame.height) - 2 * outline);
                        lv_obj_set_style_bg_color(center, lv_color_hex(0x181818), 0);
                        lv_obj_set_style_bg_opa(center, LV_OPA_COVER, 0);
                        lv_obj_set_style_radius(center, std::max(2, 5 - outline / 2), 0);
                        lv_obj_set_clickable(center, false);
                        lv_obj_set_scrollable(center, false);
                    }
                    lv_obj_set_parent(title, tile.slider);
                    lv_obj_set_pos(title, 7, 7);
                    lv_obj_set_size(title, std::max(1, int(frame.width) - 16), std::max(1, int(frame.height) - 16));
                    lv_obj_set_style_text_align(title, LV_TEXT_ALIGN_LEFT, 0);
                    lv_label_set_long_mode(title, LV_LABEL_LONG_DOT);
                    tile.filledText = lv_obj_create(tile.slider);
                    lv_obj_remove_style_all(tile.filledText);
                    lv_obj_set_hidden(tile.filledText, outline > 0);
                    lv_obj_set_size(tile.filledText, 0, int(frame.height) - 2);
                    lv_obj_set_scrollable(tile.filledText, false);
                    lv_obj_set_clickable(tile.filledText, false);
                    tile.filledTitle = lv_label_create(tile.filledText);
                    lv_obj_set_pos(tile.filledTitle, 7, 7);
                    lv_obj_set_size(tile.filledTitle, std::max(1, int(frame.width) - 16), std::max(1, int(frame.height) - 16));
                    lv_obj_set_style_text_color(tile.filledTitle, lv_color_hex(0x181818), 0);
                    lv_label_set_long_mode(tile.filledTitle, LV_LABEL_LONG_DOT);
                    lv_label_set_text(tile.filledTitle, control["title"] | "");
                    if (!tile.seek) {
                        for (auto* label : {title, tile.filledTitle}) {
                            lv_obj_set_size(label, std::max(1, int(frame.width) - 74), int(frame.height) - 16);
                            lv_label_set_long_mode(label, LV_LABEL_LONG_WRAP);
                            lv_obj_set_style_text_align(label, LV_TEXT_ALIGN_LEFT, 0);
                        }
                        tile.valueLabel = lv_label_create(tile.slider);
                        tile.filledValue = lv_label_create(tile.filledText);
                        for (auto* label : {tile.valueLabel, tile.filledValue}) {
                            lv_obj_set_width(label, 54);
                            lv_obj_set_style_text_align(label, LV_TEXT_ALIGN_RIGHT, 0);
                            lv_obj_set_pos(label, int(frame.width) - 63, 7);
                        }
                        lv_obj_set_style_text_color(tile.filledValue, lv_color_hex(0x181818), 0);
                    }
                    lv_obj_add_event_cb(tile.slider, onTile, LV_EVENT_ALL, &tile);
                    continue;
                }
            } else {
                const int iconSize = frame.height >= 70 ? std::min(32, int(frame.width) / 3) : 0;
                if (!text) addIcon(tile, control["symbol"] | "", iconSize);
                const int titleTop = tile.pixels ? 14 + iconSize : 4;
                lv_obj_set_height(title, std::max(1, int(frame.height) - titleTop - 6));
                lv_obj_align(title, LV_ALIGN_TOP_MID, 0, titleTop);
                if (!text) {
                    tile.jog = !std::strcmp(control["action"]["type"] | "", "openBuilds") &&
                        !std::strncmp(control["action"]["text"] | "", "continuousJog", 13);
                    lv_obj_add_event_cb(tile.widget, onTile, LV_EVENT_ALL, &tile);
                }
            }
        }
        lv_obj_update_layout(content);
    }
    void releasePointer() {
        if (auto* pointer = lv_indev_active()) {
            lv_indev_wait_release(pointer);
            return;
        }
        for (auto* pointer = lv_indev_get_next(nullptr); pointer; pointer = lv_indev_get_next(pointer)) {
            if (lv_indev_get_type(pointer) == LV_INDEV_TYPE_POINTER) {
                lv_indev_wait_release(pointer);
                return;
            }
        }
    }
    void releasePressed() {
        release(*visible);
        for (auto& tile : visible->tiles) {
            if (tile.widget) lv_obj_remove_state(tile.widget, LV_STATE_PRESSED);
            if (tile.slider) lv_obj_remove_state(tile.slider, LV_STATE_PRESSED);
        }
    }
    Page* findBuilt(size_t index) {
        for (auto& page : pages)
            if (page.index == index && page.revision == revision) return &page;
        return nullptr;
    }
    Page* freeSlot(Page* keep) {
        Page* stale = nullptr;
        for (auto& page : pages) {
            if (&page == visible || &page == keep) continue;
            if (page.index == SIZE_MAX || page.revision != revision) return &page;
            stale = &page;
        }
        return stale;
    }
    void position(int value) {
        offset = value;
        lv_obj_set_x(visible->root, offset);
        if (direction) lv_obj_set_x(neighbor->root, offset + direction * 368);
    }
    static void animatePosition(void* context, int32_t value) {
        static_cast<WavesharePageView*>(context)->position(value);
    }
    void resetMotion() {
        lv_anim_delete(this, animatePosition);
        settling = false;
        pendingPage = 0;
        direction = 0;
        requestedDirection = 0;
        offset = 0;
        swipeVelocity = 0;
        swipeMoves = 0;
        lv_obj_set_x(visible->root, 0);
        for (auto& page : pages) {
            if (&page == visible) continue;
            lv_obj_set_hidden(page.root, true);
            lv_obj_set_x(page.root, 368);
        }
    }
    void rebuild() {
        if (swipe.down) {
            ignoreTouch = true;
            swipe.down = false;
            swipe.swiped = true;
            releasePointer();
        }
        release(*visible);
        resetMotion();
        if (neighbor->index == current.pageIndex && neighbor->revision == current.profileRevision) {
            std::swap(visible, neighbor);
            lv_obj_set_hidden(visible->root, false);
            lv_obj_set_hidden(neighbor->root, true);
            lv_obj_set_x(visible->root, 0);
        } else build(*visible, current.pageIndex);
        revision = current.profileRevision;
        pageIndex = current.pageIndex;
    }
    void prepareNeighbor(int nextDirection) {
        const int count = (*current.profile)["pages"].size();
        if (count < 2) return;
        const size_t target = (int(pageIndex) + nextDirection + count) % count;
        Page* surface = findBuilt(target);
        if (!surface || surface == visible) {
            surface = freeSlot(nullptr);
            if (!surface) return;
            if (surface->index != target || surface->revision != revision) build(*surface, target);
        }
        neighbor = surface;
        direction = nextDirection;
        lv_obj_set_hidden(neighbor->root, false);
        for (auto& page : pages)
            if (&page != visible && &page != neighbor) lv_obj_set_hidden(page.root, true);
    }
    void discardStale() {
        for (auto& page : pages) {
            if (&page == visible || page.index == SIZE_MAX || page.revision == revision) continue;
            clear(page);
            page.index = SIZE_MAX;
            page.revision = UINT32_MAX;
            page.labelsReady = false;
            lv_obj_set_hidden(page.root, true);
        }
    }
    void ensureNeighbors() {
        if (swipe.down || settling || pendingPage || !current.profile || pageIndex == SIZE_MAX) return;
        discardStale();
        const int count = (*current.profile)["pages"].size();
        if (count < 2) return;
        const size_t forward = (pageIndex + 1) % count;
        const size_t backward = (pageIndex + count - 1) % count;
        if (!findBuilt(forward)) {
            if (Page* slot = freeSlot(nullptr)) {
                build(*slot, forward);
                lv_obj_set_hidden(slot->root, true);
            }
        }
        if (count > 2 && backward != forward && !findBuilt(backward)) {
            if (Page* slot = freeSlot(findBuilt(forward))) {
                build(*slot, backward);
                lv_obj_set_hidden(slot->root, true);
            }
        }
        if (Page* forwardPage = findBuilt(forward)) neighbor = forwardPage;
    }
    bool commitGesture() const {
        if (!direction) return false;
        if (std::abs(offset) >= 48) return true;
        // A short drag still changes pages when the finger is moving quickly. A
        // single coarse sample, a pause, or a reversal keeps the distance gate.
        if (swipeMoves < 2 || std::abs(offset) < 24 || std::abs(swipeVelocity) < 800) return false;
        if ((offset < 0) != (swipeVelocity < 0)) return false;
        return std::abs(offset) + std::abs(swipeVelocity) / 12 >= 56;
    }
    void settle() {
        const bool commit = commitGesture();
        pendingPage = commit ? direction : 0;
        settling = true;
        const int target = commit ? -direction * 368 : 0;
        const int remaining = std::abs(target - offset);
        const int speed = std::clamp(std::max(std::abs(swipeVelocity), 1600), 1600, 4200);
        const int duration = std::clamp(remaining * 1000 / std::max(1, speed), 70, 150);
        lv_anim_t animation;
        lv_anim_init(&animation);
        lv_anim_set_var(&animation, this);
        lv_anim_set_exec_cb(&animation, animatePosition);
        lv_anim_set_values(&animation, offset, target);
        lv_anim_set_duration(&animation, duration);
        lv_anim_set_path_cb(&animation, lv_anim_path_ease_out);
        lv_anim_set_completed_cb(&animation, [](lv_anim_t* completed) {
            auto* owner = static_cast<WavesharePageView*>(completed->var);
            owner->settling = false;
            if (!owner->pendingPage) owner->resetMotion();
        });
        lv_anim_start(&animation);
    }
public:
    void diagnostics(JsonObject json) const {
        json["ignoringTouch"] = ignoreTouch;
        json["wakeTouch"] = wakeTouch;
        json["swipeDown"] = swipe.down;
        json["settling"] = settling;
        json["pendingPage"] = pendingPage;
        json["pageOffset"] = offset;
    }
    void begin(lv_obj_t* screen) {
        for (auto& page : pages) {
            page.root = lv_obj_create(screen);
            lv_obj_remove_style_all(page.root);
            lv_obj_set_size(page.root, 368, 448);
            lv_obj_set_scrollable(page.root, false);
            lv_obj_set_style_bg_color(page.root, lv_color_black(), 0);
            lv_obj_set_style_bg_opa(page.root, LV_OPA_COVER, 0);
            page.header = lv_label_create(page.root);
            lv_obj_set_width(page.header, 340);
            lv_obj_align(page.header, LV_ALIGN_TOP_MID, 0, 6);
            lv_obj_set_style_text_align(page.header, LV_TEXT_ALIGN_CENTER, 0);
            lv_label_set_long_mode(page.header, LV_LABEL_LONG_DOT);
            lv_label_set_text(page.header, "OP Remote");
            page.clock = lv_label_create(page.root);
            lv_obj_set_width(page.clock, 190);
            lv_obj_align(page.clock, LV_ALIGN_TOP_RIGHT, -8, 6);
            lv_obj_set_style_text_align(page.clock, LV_TEXT_ALIGN_RIGHT, 0);
            lv_label_set_long_mode(page.clock, LV_LABEL_LONG_DOT);
            lv_label_set_text(page.clock, "");
            page.content = lv_obj_create(page.root);
            lv_obj_remove_style_all(page.content);
            lv_obj_set_pos(page.content, 0, pageHeaderHeight);
            lv_obj_set_size(page.content, 368, 448 - pageHeaderHeight);
            lv_obj_set_scrollable(page.content, false);
        }
        for (auto& page : pages) if (&page != visible) lv_obj_set_hidden(page.root, true);
    }
    bool blocksTouch() const { return current.screensaver || wakeTouch; }
    bool gestureActive() const { return (swipe.down && swipe.swiped) || settling || pendingPage; }
    bool sliderHeld() const { return swipe.down && swipe.slider; }
    void setPointer(bool (*read)(int& x, int& y)) { readPointer = read; }
    void touch(int x, int y, bool down) {
        if (down && current.activity) current.activity();
        if (current.screensaver || wakeTouch) {
            wakeTouch = down;
            swipe.down = false;
            return;
        }
        if (ignoreTouch) {
            if (!down) ignoreTouch = false;
            return;
        }
        if (settling || pendingPage) {
            if (down) {
                ignoreTouch = true;
                releasePointer();
            }
            return;
        }
        if (!down) {
            const bool heldSlider = swipe.down && swipe.slider;
            const bool dragged = swipe.down && swipe.swiped;
            if (heldSlider) finishSeek(x);
            swipe.down = false;
            if (dragged) settle();
            return;
        }
        if (!swipe.down) {
            swipe.begin(x, y, sliderAt(x, y));
            swipeSampleX = x;
            swipeSampleAt = lv_tick_get();
            swipeMoves = 0;
            swipeVelocity = 0;
        }
        if (swipe.slider || !current.profile || (*current.profile)["pages"].size() < 2) {
            if (swipe.slider) holdSeek(x);
            return;
        }
        const int horizontal = x - swipe.startX;
        const int vertical = y - swipe.startY;
        if (!swipe.swiped && std::abs(horizontal) >= 12 &&
            std::abs(horizontal) > std::abs(vertical) * 1.4) {
            if (auto* tile = sliderAt(x, y)) {
                swipe.slider = true;
                if (tile->seek) placeSeek(*tile, x);
                return;
            }
            swipe.swiped = true;
            releasePressed();
            releasePointer();
        }
        if (swipe.swiped) {
            const uint32_t now = lv_tick_get();
            if (swipeSampleAt && now > swipeSampleAt && now - swipeSampleAt < 80) {
                const int instant = (x - swipeSampleX) * 1000 / int(now - swipeSampleAt);
                swipeVelocity = swipeMoves ? (swipeVelocity + instant * 2) / 3 : instant;
            }
            swipeSampleX = x;
            swipeSampleAt = now;
            ++swipeMoves;
            const int nextDirection = horizontal < 0 ? 1 : -1;
            offset = std::clamp(horizontal, -368, 368);
            requestedDirection = nextDirection;
            if (nextDirection != direction) prepareNeighbor(nextDirection);
            position(offset);
        }
    }
    void poll(const WaveshareUiState& state) {
        current = state;
        if (readPointer) {
            int x = 0, y = 0;
            const bool down = readPointer(x, y);
            touch(x, y, down);
        }
        if (imageRevision != state.imageRevision) {
            imageRevision = state.imageRevision;
            revision = UINT32_MAX;
            for (auto& page : pages) page.revision = UINT32_MAX;
        }
        const bool needsRebuild = revision != state.profileRevision || pageIndex != state.pageIndex;
        if (needsRebuild) rebuild();
        if (!saver) {
            saver = lv_image_create(lv_obj_get_parent(visible->root));
            lv_obj_set_pos(saver, 0, 0);
            lv_obj_set_size(saver, 368, 448);
            lv_obj_set_clickable(saver, true);
        }
        if (saverImage.data != state.screenImage) {
            lv_image_cache_drop(&saverImage);
            saverImage = {};
            saverImage.header.magic = LV_IMAGE_HEADER_MAGIC;
            saverImage.header.cf = LV_COLOR_FORMAT_RGB565;
            saverImage.header.w = 368;
            saverImage.header.h = 448;
            saverImage.header.stride = 736;
            saverImage.data_size = 368 * 448 * 2;
            saverImage.data = state.screenImage;
            if (state.screenImage) lv_image_set_src(saver, &saverImage);
        }
        lv_obj_set_hidden(saver, !state.screensaver || !state.screenImage);
        if (state.screensaver) {
            release(*visible);
            lv_timer_handler();
            return;
        }
        const bool gesturing = gestureActive();
        if (current.profile) {
            for (auto& surface : pages) {
                if (surface.revision != revision) continue;
                if (!lv_obj_is_visible(surface.root)) {
                    surface.labelsReady = false;
                    continue;
                }
                if (gesturing && surface.labelsReady) continue;
                surface.labelsReady = true;
                const PageMediaState* clockState = nullptr;
                Tile* clockTile = nullptr;
                bool keepClock = false;
                for (auto& tile : surface.tiles) {
                    if (!tile.slider) continue;
                    pollAction.modifierCount = 0;
                    auto& action = pollAction;
                    if (!parseAction((*current.profile)["pages"][surface.index]["controls"][tile.index]["action"], action)) continue;
                    const double value = nativeControlValue(action);
                    if (tile.seek) {
                        const auto* media = current.mediaState ? current.mediaState(action) : nullptr;
                        const bool available = media && media->timeline.available && media->timeline.durationMilliseconds;
                        const bool trackChanged = media && tile.seekTrackRevision != media->trackRevision;
                        if (trackChanged) {
                            tile.seekTrackRevision = media->trackRevision;
                            if (available) {
                                tile.pendingSeek = false;
                                if (!(swipe.down && swipe.slider && tile.down)) tile.down = false;
                                tile.seekActionValue = action.value;
                            } else if (!(swipe.down && swipe.slider && tile.down)) tile.down = false;
                        }
                        tile.seekAvailable = available;
                        lv_obj_set_clickable(tile.slider, available);
                        if (!available && !tile.pendingSeek) tile.down = false;
                        const bool dragging = tile.down || lv_slider_is_dragged(tile.slider);
                        if (action.value != tile.seekActionValue) {
                            tile.seekActionValue = action.value;
                            if (available && !dragging) {
                                tile.pendingSeek = true;
                                tile.seekAt = current.now;
                                tile.seekValue = int(std::round(value * 10));
                                lv_slider_set_value(tile.slider, tile.seekValue, LV_ANIM_OFF);
                            }
                        }
                        const uint32_t elapsed = available ? media_timeline::elapsedAt(media->timeline, current.now) : 0;
                        const int liveValue = available ? int(uint64_t(elapsed) * 1000 / media->timeline.durationMilliseconds) : 0;
                        const int expectedValue = tile.seekValue + (available && media->timeline.playing
                            ? int(uint64_t(current.now - tile.seekAt) * 1000 / media->timeline.durationMilliseconds) : 0);
                        if (tile.pendingSeek && available && (current.now - tile.seekAt >= 3000 ||
                            (int32_t(media->timeline.sampledAt - tile.seekAt) > 0 &&
                             std::abs(liveValue - expectedValue) <= 8))) tile.pendingSeek = false;
                        if (!dragging && !tile.pendingSeek)
                            lv_slider_set_value(tile.slider, liveValue, LV_ANIM_OFF);
                        lv_obj_set_width(tile.filledText, lv_slider_get_value(tile.slider) * lv_obj_get_width(tile.slider) / 1000);
                        if (!(tile.pendingSeek && !available)) {
                            const char* text = media && media->text[0] ? media->text :
                                ((*current.profile)["pages"][surface.index]["controls"][tile.index]["title"] | "");
                            layoutSeekText(tile, (*current.profile)["pages"][surface.index]["controls"][tile.index], text);
                        }
                        if (available && (!clockState || dragging)) { clockState = media; clockTile = &tile; }
                        else if (tile.pendingSeek) keepClock = true;
                        continue;
                    }
                    if (!lv_slider_is_dragged(tile.slider))
                        lv_slider_set_value(tile.slider, int(std::round(value * 10)), LV_ANIM_OFF);
                    const int minimum = lv_slider_get_min_value(tile.slider);
                    const int maximum = lv_slider_get_max_value(tile.slider);
                    const int sliderValue = lv_slider_get_value(tile.slider);
                    lv_obj_set_width(tile.filledText, (sliderValue - minimum) * lv_obj_get_width(tile.slider) /
                        std::max(1, maximum - minimum));
                    const double displayedValue = sliderValue / 10.0;
                    char label[24];
                    if (tile.temperature) std::snprintf(label, sizeof(label), "%.1f", displayedValue);
                    else std::snprintf(label, sizeof(label), "%.0f%%", tile.brightness ? displayedValue * 100 / 255 : displayedValue);
                    setText(tile.valueLabel, label);
                    setText(tile.filledValue, label);
                }
                if (clockState) {
                    const uint32_t duration = clockState->timeline.durationMilliseconds / 1000;
                    const uint32_t elapsed = clockTile->down || clockTile->pendingSeek
                        ? uint64_t(clockState->timeline.durationMilliseconds) * lv_slider_get_value(clockTile->slider) / 1000000
                        : media_timeline::elapsedAt(clockState->timeline, current.now) / 1000;
                    char label[40];
                    std::snprintf(label, sizeof(label), "%lu:%02lu / %lu:%02lu",
                        static_cast<unsigned long>(elapsed / 60), static_cast<unsigned long>(elapsed % 60),
                        static_cast<unsigned long>(duration / 60), static_cast<unsigned long>(duration % 60));
                    setText(surface.clock, label);
                } else if (!keepClock) setText(surface.clock, "");
                if (!keepClock && surface.showsClock != (clockState != nullptr)) {
                    surface.showsClock = clockState != nullptr;
                    lv_obj_set_width(surface.header, clockState ? 150 : 340);
                    lv_obj_align(surface.header, clockState ? LV_ALIGN_TOP_LEFT : LV_ALIGN_TOP_MID, clockState ? 8 : 0, 6);
                    lv_obj_set_style_text_align(surface.header, clockState ? LV_TEXT_ALIGN_LEFT : LV_TEXT_ALIGN_CENTER, 0);
                }
            }
        }
        lv_timer_handler();
        if (requestedDirection && requestedDirection != direction && swipe.down && !settling) {
            prepareNeighbor(requestedDirection);
            position(offset);
        }
        bool changedPage = false;
        if (pendingPage && !settling) {
            const int delta = pendingPage;
            pendingPage = 0;
            changedPage = true;
            if (current.changePage) current.changePage(delta);
            else resetMotion();
        }
        if (!changedPage && !needsRebuild) ensureNeighbors();
    }
};
}