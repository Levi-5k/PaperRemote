idf_component_register(
    SRCS "app_main.cpp" "bluetooth.cpp" "profile_store.cpp" "media_store.cpp" "network.cpp" "../../src/waveshare_amoled_18.cpp"
    INCLUDE_DIRS "." "../../include"
    REQUIRES esp_timer esp_driver_gpio esp_driver_i2c esp_driver_spi esp_psram
             nvs_flash esp_wifi esp_netif esp_event esp_http_client esp_http_server bt
             fatfs sdmmc esp_driver_sdmmc
)
target_compile_features(${COMPONENT_LIB} PUBLIC cxx_std_17)
target_compile_options(${COMPONENT_LIB} PRIVATE -fdiagnostics-format=sarif-file -fstack-usage)
idf_component_get_property(LVGL_LIB lvgl__lvgl COMPONENT_LIB)
target_compile_definitions(${LVGL_LIB} PUBLIC
    LV_KCONFIG_IGNORE
    LV_CONF_PATH="${CMAKE_CURRENT_LIST_DIR}/../../include/lv_conf.h"
)
target_compile_definitions(${COMPONENT_LIB} PUBLIC
    PAPERGIF_WAVESHARE_AMOLED_18=1
    PAPERGIF_SUPERMINI_S3=1
    PAPERGIF_NATIVE_IDF=1
    PAPERGIF_FIRMWARE_VERSION="1.0.7"
    LV_CONF_INCLUDE_SIMPLE
)