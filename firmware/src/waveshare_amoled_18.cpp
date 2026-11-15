#include "waveshare_amoled_18_board.h"

#include <driver/gpio.h>
#include <driver/spi_master.h>
#include <esp_heap_caps.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>
#include <freertos/semphr.h>
#include <freertos/task.h>
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <lvgl.h>
#include "waveshare_page_view.h"

namespace paper_board {
uint32_t panelFlushes = 0;
constexpr int kWidth = 368;
constexpr int kHeight = 448;
constexpr int kColumnOffset = 16;
constexpr int kDrawRows = kHeight;
constexpr size_t kDrawBytes = kWidth * kDrawRows * sizeof(uint16_t);
constexpr int kChunkRows = 16;
constexpr size_t kDmaBytes = kWidth * kChunkRows * sizeof(uint16_t);
constexpr size_t kDmaBuffers = 2;
constexpr int kQspiClockHz = 40 * 1000 * 1000;
constexpr gpio_num_t kCs = GPIO_NUM_12;
constexpr uint8_t kExpander = 0x20;
constexpr uint8_t kTouch = 0x15;

static_assert(LV_COLOR_FORMAT_DEFAULT == LV_COLOR_FORMAT_RGB565,
              "AMOLED flush swaps native RGB565 once");

static bool i2cWrite(uint8_t address, uint8_t reg, uint8_t value) {
    return hardware::writeRegister(address, reg, value);
}

static void copySwap565(uint8_t* destination, const uint8_t* source, size_t pixels) {
    size_t index = 0;
    if (((reinterpret_cast<uintptr_t>(destination) | reinterpret_cast<uintptr_t>(source)) & 3) == 0) {
        auto* dst = reinterpret_cast<uint32_t*>(destination);
        auto* src = reinterpret_cast<const uint32_t*>(source);
        const size_t pairs = pixels / 2;
        size_t pair = 0;
        for (; pair + 4 <= pairs; pair += 4) {
            const uint32_t a = src[pair], b = src[pair + 1], c = src[pair + 2], d = src[pair + 3];
            dst[pair] = ((a & 0x00ff00ffu) << 8) | ((a & 0xff00ff00u) >> 8);
            dst[pair + 1] = ((b & 0x00ff00ffu) << 8) | ((b & 0xff00ff00u) >> 8);
            dst[pair + 2] = ((c & 0x00ff00ffu) << 8) | ((c & 0xff00ff00u) >> 8);
            dst[pair + 3] = ((d & 0x00ff00ffu) << 8) | ((d & 0xff00ff00u) >> 8);
        }
        for (; pair < pairs; ++pair) {
            const uint32_t value = src[pair];
            dst[pair] = ((value & 0x00ff00ffu) << 8) | ((value & 0xff00ff00u) >> 8);
        }
        index = pairs * 2;
    }
    for (; index < pixels; ++index) {
        destination[index * 2] = source[index * 2 + 1];
        destination[index * 2 + 1] = source[index * 2];
    }
}

class Panel {
    spi_device_handle_t spi = nullptr;
    uint8_t* dma = nullptr;
    bool busReady = false;

    void cs(bool selected) { gpio_set_level(kCs, selected ? 0 : 1); }

    bool command(uint8_t cmd, const uint8_t* data, size_t length) {
        if (!spi || length > 4) return false;
        spi_transaction_t transfer{};
        transfer.flags = SPI_TRANS_MULTILINE_CMD | SPI_TRANS_MULTILINE_ADDR;
        transfer.cmd = 0x02;
        transfer.addr = uint32_t(cmd) << 8;
        if (length) {
            transfer.flags |= SPI_TRANS_USE_TXDATA;
            transfer.length = length * 8;
            for (size_t i = 0; i < length; ++i) transfer.tx_data[i] = data[i];
        }
        cs(true);
        const esp_err_t result = spi_device_polling_transmit(spi, &transfer);
        cs(false);
        return result == ESP_OK;
    }

    bool pixels(const uint8_t* source, size_t count) {
        if (!spi || !dma) return false;
        if (spi_device_acquire_bus(spi, portMAX_DELAY) != ESP_OK) return false;
        cs(true);
        bool first = true;
        bool success = true;
        spi_transaction_ext_t transfers[kDmaBuffers]{};
        size_t submitted = 0;
        size_t completed = 0;
        while (count) {
            if (submitted - completed == kDmaBuffers) {
                spi_transaction_t* finished = nullptr;
                ESP_ERROR_CHECK(spi_device_get_trans_result(spi, &finished, portMAX_DELAY));
                ++completed;
            }
            const size_t slot = submitted % kDmaBuffers;
            uint8_t* staging = dma + slot * kDmaBytes;
            const size_t chunk = count > kDmaBytes / 2 ? kDmaBytes / 2 : count;
            copySwap565(staging, source, chunk);
            auto& transfer = transfers[slot];
            transfer = {};
            if (first) {
                transfer.base.flags = SPI_TRANS_MODE_QIO;
                transfer.base.cmd = 0x32;
                transfer.base.addr = 0x003C00;
                first = false;
            } else {
                transfer.base.flags = SPI_TRANS_MODE_QIO | SPI_TRANS_VARIABLE_CMD |
                    SPI_TRANS_VARIABLE_ADDR | SPI_TRANS_VARIABLE_DUMMY;
                transfer.command_bits = 0;
                transfer.address_bits = 0;
                transfer.dummy_bits = 0;
            }
            transfer.base.tx_buffer = staging;
            transfer.base.length = chunk * 16;
            if (spi_device_queue_trans(spi, &transfer.base, portMAX_DELAY) != ESP_OK) {
                success = false;
                break;
            }
            ++submitted;
            source += chunk * 2;
            count -= chunk;
        }
        while (completed < submitted) {
            spi_transaction_t* finished = nullptr;
            ESP_ERROR_CHECK(spi_device_get_trans_result(spi, &finished, portMAX_DELAY));
            ++completed;
        }
        cs(false);
        spi_device_release_bus(spi);
        return success;
    }

public:
    bool begin() {
        gpio_config_t chipSelect{};
        chipSelect.pin_bit_mask = 1ULL << kCs;
        chipSelect.mode = GPIO_MODE_OUTPUT;
        if (gpio_config(&chipSelect) != ESP_OK) return false;
        gpio_set_level(kCs, 1);
        dma = static_cast<uint8_t*>(heap_caps_aligned_alloc(16, kDmaBytes * kDmaBuffers, MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL));
        if (!dma) return false;

        spi_bus_config_t bus{};
        bus.mosi_io_num = 4;
        bus.miso_io_num = 5;
        bus.sclk_io_num = 11;
        bus.quadwp_io_num = 6;
        bus.quadhd_io_num = 7;
        bus.max_transfer_sz = int(kDmaBytes);
        bus.flags = SPICOMMON_BUSFLAG_MASTER | SPICOMMON_BUSFLAG_GPIO_PINS;
        if (spi_bus_initialize(SPI2_HOST, &bus, SPI_DMA_CH_AUTO) != ESP_OK) return false;
        busReady = true;

        spi_device_interface_config_t device{};
        device.command_bits = 8;
        device.address_bits = 24;
        device.mode = 0;
        device.clock_speed_hz = kQspiClockHz;
        device.spics_io_num = -1;
        device.flags = SPI_DEVICE_HALFDUPLEX;
        device.queue_size = kDmaBuffers;
        if (spi_bus_add_device(SPI2_HOST, &device, &spi) != ESP_OK) return false;

        auto data = [&](uint8_t cmd, uint8_t value) { return command(cmd, &value, 1); };
        if (!command(0x01, nullptr, 0)) return false;
        hardware::wait(200);
        if (!command(0x11, nullptr, 0)) return false;
        hardware::wait(120);
        if (!data(0xFE, 0x00) || !data(0xC4, 0x80) || !data(0x3A, 0x55) || !data(0x53, 0x20) ||
            !data(0x63, 0xFF) || !command(0x29, nullptr, 0) || !data(0x51, 0xD0) || !data(0x58, 0x00))
            return false;
        hardware::wait(10);
        return command(0x20, nullptr, 0) && data(0x36, 0x00);
    }

    void flush(const lv_area_t* area, const uint8_t* pixelsIn) {
        const int x = area->x1 + kColumnOffset;
        const int x2 = area->x2 + kColumnOffset;
        const uint8_t column[] = {uint8_t(x >> 8), uint8_t(x), uint8_t(x2 >> 8), uint8_t(x2)};
        const uint8_t row[] = {uint8_t(area->y1 >> 8), uint8_t(area->y1), uint8_t(area->y2 >> 8), uint8_t(area->y2)};
        const size_t count = size_t(area->x2 - area->x1 + 1) * size_t(area->y2 - area->y1 + 1);
        if (command(0x2A, column, 4) && command(0x2B, row, 4) && command(0x2C, nullptr, 0))
            pixels(pixelsIn, count);
        else {
            static bool logged = false;
            if (!logged) {
                logged = true;
                hardware::log("AMOLED flush failed\n");
            }
        }
        ++panelFlushes;
    }
};

struct CachedTouch {
    uint32_t generation = 1;
    uint32_t sampled = 0;
    int x = 0;
    int y = 0;
    bool down = false;
};
static CachedTouch cachedTouch;

static bool readTouch(int& x, int& y) {
    uint8_t bytes[5];
    if (!hardware::readRegister(kTouch, 0x02, bytes, sizeof(bytes))) return false;
    const int fingers = bytes[0];
    const int xh = bytes[1];
    const int xl = bytes[2];
    const int yh = bytes[3];
    const int yl = bytes[4];
    if (fingers <= 0) return false;
    x = ((xh & 0x0F) << 8) | xl;
    y = ((yh & 0x0F) << 8) | yl;
    if (x < 0 || y < 0 || x >= kWidth || y >= kHeight) {
        static bool logged = false;
        if (!logged) {
            logged = true;
            hardware::log("Touch coordinate out of range: %d,%d\n", x, y);
        }
        return false;
    }
    return true;
}

static void beginTouchSample() { ++cachedTouch.generation; }

static bool sampleTouch(int& x, int& y) {
    if (cachedTouch.sampled != cachedTouch.generation) {
        cachedTouch.sampled = cachedTouch.generation;
        int nextX = 0, nextY = 0;
        cachedTouch.down = readTouch(nextX, nextY);
        if (cachedTouch.down) {
            cachedTouch.x = nextX;
            cachedTouch.y = nextY;
        }
    }
    x = cachedTouch.x;
    y = cachedTouch.y;
    return cachedTouch.down;
}

static void (*pollActive)(const WaveshareUiState*) = nullptr;
static bool (*gestureQuery)() = nullptr;
static bool (*sliderQuery)() = nullptr;

class WaveshareAmoled18Board::Screen : public DisplayDriver {
    WaveshareAmoled18Board& board;
    Panel panel;
    bool ready = false;
    uint32_t lastTick = 0;
    WavesharePageView pages;
    void* drawBuffer = nullptr;
    void* secondDrawBuffer = nullptr;
    struct FlushJob {
        lv_area_t area;
        const uint8_t* pixels;
        bool last;
    };
    QueueHandle_t flushQueue = nullptr;
    SemaphoreHandle_t flushDone = nullptr;
    TaskHandle_t flushTask = nullptr;
    lv_display_t* displayHandle = nullptr;
    bool flushPending = false;
    std::atomic<uint32_t> transferMicros{0};
    std::atomic<uint32_t> transferredFrames{0};
    uint32_t measuredAt = 0, uiMicros = 0, uiPolls = 0, longestPoll = 0;
    uint32_t sampledFrames = 0, sampledWindow = 0, sampledTransfer = 0, sampledMaxPoll = 0;

    static void transferWorker(void* context) {
        auto* screen = static_cast<Screen*>(context);
        FlushJob job{};
        for (;;) {
            if (xQueueReceive(screen->flushQueue, &job, portMAX_DELAY) != pdTRUE) continue;
            const uint32_t started = hardware::microsNow();
            screen->panel.flush(&job.area, job.pixels);
            screen->transferMicros.fetch_add(hardware::microsNow() - started, std::memory_order_relaxed);
            if (job.last) screen->transferredFrames.fetch_add(1, std::memory_order_relaxed);
            xSemaphoreGive(screen->flushDone);
        }
    }

    static Screen* active;

    static void flushCallback(lv_display_t* display, const lv_area_t* area, uint8_t* pixels) {
        if (!active || !active->flushTask) {
            if (active) active->panel.flush(area, pixels);
            lv_display_flush_ready(display);
            return;
        }
        const FlushJob job{*area, pixels, lv_display_flush_is_last(display)};
        if (xQueueSend(active->flushQueue, &job, portMAX_DELAY) != pdTRUE) abort();
        active->flushPending = true;
    }
    static void flushWaitCallback(lv_display_t*) {
        if (active && active->flushTask) {
            if (xSemaphoreTake(active->flushDone, portMAX_DELAY) != pdTRUE) abort();
            active->flushPending = false;
        }
    }
    static void touchCallback(lv_indev_t*, lv_indev_data_t* data) {
        int x = 0, y = 0;
        const bool down = sampleTouch(x, y);
        if (down && (!active || !active->pages.blocksTouch())) data->state = LV_INDEV_STATE_PRESSED;
        else data->state = LV_INDEV_STATE_RELEASED;
        data->point.x = x;
        data->point.y = y;
    }
    bool gestureActive() const { return pages.gestureActive(); }
    bool sliderHeld() const { return pages.sliderHeld(); }

public:
    explicit Screen(WaveshareAmoled18Board& owner) : board(owner) {
        active = this;
        pollActive = [](const WaveshareUiState* state) {
            if (active && state) active->poll(*state);
        };
        sliderQuery = [] { return active && active->sliderHeld(); };
        gestureQuery = [] { return active && active->gestureActive(); };
    }
    ~Screen() override {
        if (flushPending) flushWaitCallback(displayHandle);
        if (displayHandle) {
            lv_display_flush_ready(displayHandle);
            lv_display_delete(displayHandle);
        }
        if (flushTask) vTaskDelete(flushTask);
        if (flushQueue) vQueueDelete(flushQueue);
        if (flushDone) vSemaphoreDelete(flushDone);
        heap_caps_free(drawBuffer);
        heap_caps_free(secondDrawBuffer);
        if (active == this) {
            active = nullptr;
            pollActive = nullptr;
            sliderQuery = nullptr;
            gestureQuery = nullptr;
        }
    }
    const DisplayInfo* info() const override { return waveshareAmoled18V2().display; }
    bool alive() const { return ready; }
    void diagnostics(JsonObject json) {
        json["ready"] = ready;
        json["flushPending"] = flushPending;
        json["fullFrameRendering"] = false;
        json["fullScreenDrawBuffers"] = true;
        json["drawBufferBytes"] = kDrawBytes * 2;
        json["dmaBufferBytes"] = kDmaBytes * kDmaBuffers;
        json["qspiClockHz"] = kQspiClockHz;
        json["internalFreeBytes"] = heap_caps_get_free_size(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
        json["mainStackFreeBytes"] = uxTaskGetStackHighWaterMark(nullptr);
        if (flushTask) json["transferStackFreeBytes"] = uxTaskGetStackHighWaterMark(flushTask);
        json["refreshes"] = sampledFrames;
        json["windowMilliseconds"] = sampledWindow;
        json["transferMicrosecondsPerRefresh"] = sampledTransfer;
        json["maxUiPollMicroseconds"] = sampledMaxPoll;
        uint8_t bytes[5]{};
        const bool read = hardware::readRegister(kTouch, 0x02, bytes, sizeof(bytes));
        json["touchReadSuccess"] = read;
        if (read) {
            json["touchFingers"] = bytes[0];
            json["touchX"] = ((bytes[1] & 15) << 8) | bytes[2];
            json["touchY"] = ((bytes[3] & 15) << 8) | bytes[4];
        }
        if (ready) {
            lv_mem_monitor_t memory{};
            lv_mem_monitor(&memory);
            json["lvglFreeBytes"] = memory.free_size;
            json["lvglLargestFreeBytes"] = memory.free_biggest_size;
            pages.diagnostics(json);
        }
    }

    void begin() override {
        hardware::beginI2C(PAPERGIF_AMOLED_MT6701_SDA_PIN, PAPERGIF_AMOLED_MT6701_SCL_PIN);
        if (!i2cWrite(kExpander, 0x03, 0xF8))
            hardware::log("TCA9554 config failed; AMOLED power may stay off\n");
        i2cWrite(kExpander, 0x01, 0x00);
        hardware::wait(20);
        i2cWrite(kExpander, 0x01, 0x07);
        hardware::wait(30);
        if (!panel.begin()) {
            hardware::log("AMOLED panel init failed; buttons and dial still work\n");
            return;
        }

        uint8_t touchID = 0;
        if (hardware::readRegister(kTouch, 0xA7, &touchID, 1))
            hardware::log("Touch chip ID 0x%02X\n", touchID);
        else hardware::log("CST820 touch not responding; on-screen buttons stay inactive\n");

        drawBuffer = heap_caps_malloc(kDrawBytes, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
        secondDrawBuffer = heap_caps_malloc(kDrawBytes, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
        if (!drawBuffer || !secondDrawBuffer) {
            hardware::log("AMOLED draw buffer allocation failed\n");
            return;
        }
        flushQueue = xQueueCreate(1, sizeof(FlushJob));
        flushDone = xSemaphoreCreateBinary();
        if (!flushQueue || !flushDone || xTaskCreatePinnedToCore(transferWorker, "amoled-transfer", 3072,
            this, 1, &flushTask, 1) != pdPASS) {
            hardware::log("AMOLED transfer worker allocation failed\n");
            return;
        }
        lv_init();
        auto* display = lv_display_create(kWidth, kHeight);
        displayHandle = display;
        lv_display_set_color_format(display, LV_COLOR_FORMAT_RGB565);
        lv_display_set_buffers(display, drawBuffer, secondDrawBuffer, kDrawBytes, LV_DISPLAY_RENDER_MODE_PARTIAL);
        lv_display_set_flush_cb(display, flushCallback);
        lv_display_set_flush_wait_cb(display, flushWaitCallback);

        auto* pointer = lv_indev_create();
        lv_indev_set_type(pointer, LV_INDEV_TYPE_POINTER);
        lv_indev_set_read_cb(pointer, touchCallback);
        lv_timer_set_period(lv_indev_get_read_timer(pointer), 16);

        auto* screen = lv_screen_active();
        lv_obj_set_style_bg_color(screen, lv_color_hex(0x000000), 0);
        lv_obj_set_style_text_color(screen, lv_color_hex(0xF2F2F2), 0);
        lv_obj_set_scrollable(screen, false);

        pages.begin(screen);
        pages.setPointer(sampleTouch);
        lv_tick_inc(1);
        lv_timer_handler();
        lastTick = hardware::millisNow();
        measuredAt = lastTick;
        ready = true;
        hardware::log("AMOLED LVGL 9.6 ready; free internal %u, free PSRAM %u\n",
            unsigned(heap_caps_get_free_size(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT)),
            unsigned(heap_caps_get_free_size(MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT)));
    }
    void drawControl(const char*, const Rect&) override {}
    void present() override {}

    void poll(const WaveshareUiState& state) {
        if (!ready) return;
        const uint32_t now = hardware::millisNow();
        uint32_t elapsed = now - lastTick;
        if (elapsed > 100) elapsed = 100;
        beginTouchSample();
        lv_tick_inc(elapsed);
        lastTick = now;
        const uint32_t started = hardware::microsNow();
        pages.poll(state);
        const uint32_t duration = hardware::microsNow() - started;
        uiMicros += duration;
        ++uiPolls;
        longestPoll = std::max(longestPoll, duration);
        if (now - measuredAt >= 2000) {
            const uint32_t frames = transferredFrames.exchange(0, std::memory_order_relaxed);
            const uint32_t transfer = transferMicros.exchange(0, std::memory_order_relaxed);
            sampledFrames = frames;
            sampledWindow = now - measuredAt;
            sampledTransfer = frames ? transfer / frames : 0;
            sampledMaxPoll = longestPoll;
            if (frames) hardware::log("AMOLED perf: %u frames/%u ms, transfer %u us/frame, UI avg %u us max %u us\n",
                unsigned(frames), unsigned(now - measuredAt), unsigned(transfer / frames),
                unsigned(uiMicros / uiPolls), unsigned(longestPoll));
            measuredAt = now;
            uiMicros = uiPolls = longestPoll = 0;
        }
    }
};

WaveshareAmoled18Board::Screen* WaveshareAmoled18Board::Screen::active = nullptr;

WaveshareAmoled18Board::WaveshareAmoled18Board()
    : SuperMiniS3Board(PAPERGIF_AMOLED_BUTTON_1_PIN, PAPERGIF_AMOLED_BUTTON_2_PIN,
                       PAPERGIF_AMOLED_MT6701_SDA_PIN, PAPERGIF_AMOLED_MT6701_SCL_PIN),
      screen(new Screen(*this)) {}

WaveshareAmoled18Board::~WaveshareAmoled18Board() { delete screen; }

DisplayDriver* WaveshareAmoled18Board::display() { return screen; }
void WaveshareAmoled18Board::displayDiagnostics(JsonObject json) {
    if (screen) screen->diagnostics(json);
}

void waveshareUiPoll(const WaveshareUiState& state) {
    if (pollActive) pollActive(&state);
}
bool waveshareUiGestureActive() {
    return gestureQuery && gestureQuery();
}
bool waveshareUiSliderHeld() {
    return sliderQuery && sliderQuery();
}
}
