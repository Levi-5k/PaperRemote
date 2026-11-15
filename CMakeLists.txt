cmake_minimum_required(VERSION 3.16)

set(IDF_TARGET esp32s3)
set(SDKCONFIG "${CMAKE_CURRENT_LIST_DIR}/firmware/idf/sdkconfig")
set(SDKCONFIG_DEFAULTS "${CMAKE_CURRENT_LIST_DIR}/firmware/idf/sdkconfig.defaults")
set(EXTRA_COMPONENT_DIRS "${CMAKE_CURRENT_LIST_DIR}/firmware/idf/main")
set(LV_BUILD_CONF_PATH "${CMAKE_CURRENT_LIST_DIR}/firmware/include/lv_conf.h" CACHE PATH "LVGL configuration")
include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(paperremote_amoled VERSION 1.0.7)