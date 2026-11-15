#ifndef LV_CONF_H
#define LV_CONF_H

// LVGL 9.6 fills every unspecified option. RGB565 is that default; the panel
// flush byte-swaps it once, so do not also select the swapped format.
#define LV_USE_OS LV_OS_NONE
#define LV_DEF_REFR_PERIOD 16
#define LV_MEM_SIZE (256 * 1024U)
#if defined(ESP_PLATFORM) || defined(ARDUINO_ARCH_ESP32)
#define LV_MEM_POOL_INCLUDE "esp_heap_caps.h"
#define LV_MEM_POOL_ALLOC(size) heap_caps_malloc((size), MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT)
#endif
#define LV_INDEV_DEF_LONG_PRESS_TIME 600
#define LV_FONT_MONTSERRAT_14 1
#define LV_FONT_MONTSERRAT_20 1
#define LV_FONT_MONTSERRAT_28 1
#define LV_USE_ARC 1
#define LV_USE_BUTTON 1
#define LV_THEME_DEFAULT_DARK 1
#define LV_BUILD_EXAMPLES 0
#define LV_BUILD_DEMOS 0

#endif
