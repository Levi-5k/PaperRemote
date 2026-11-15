#include "bluetooth.h"
#include "descriptor_lease.h"
#include "esp_log.h"
#include "esp_heap_caps.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "host/ble_hs.h"
#include "host/ble_hs_mbuf.h"
#include "host/util/util.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"
#include <algorithm>
#include <cstring>

namespace native_device {
namespace {
constexpr const char* tag = "bluetooth";
const ble_uuid128_t serviceUUID = BLE_UUID128_INIT(1, 0, 0x46, 0x49, 0x47, 0x50, 0x42, 0x9c, 0x7b, 0x4c, 0x2a, 0x7d, 1, 0, 0x23, 0x7a);
const ble_uuid128_t controlUUID = BLE_UUID128_INIT(1, 0, 0x46, 0x49, 0x47, 0x50, 0x42, 0x9c, 0x7b, 0x4c, 0x2a, 0x7d, 2, 0, 0x23, 0x7a);
const ble_uuid128_t dataUUID = BLE_UUID128_INIT(1, 0, 0x46, 0x49, 0x47, 0x50, 0x42, 0x9c, 0x7b, 0x4c, 0x2a, 0x7d, 3, 0, 0x23, 0x7a);
const ble_uuid128_t descriptorUUID = BLE_UUID128_INIT(1, 0, 0x46, 0x49, 0x47, 0x50, 0x42, 0x9c, 0x7b, 0x4c, 0x2a, 0x7d, 4, 0, 0x23, 0x7a);
struct Connection {
    uint16_t handle = noConnection;
    bool subscribed = false;
    paper_board::DescriptorLease descriptor;
};
Connection peers[2];
portMUX_TYPE peerLock = portMUX_INITIALIZER_UNLOCKED;
QueueHandle_t packets = nullptr;
std::string descriptorJSON;
uint16_t controlHandle = 0;
uint8_t addressType = 0;
ble_gatt_chr_def characteristics[4]{};
ble_gatt_svc_def services[2]{};

uint32_t now() { return uint32_t(esp_timer_get_time() / 1000); }
int gapEvent(ble_gap_event* event, void*);
void advertise() {
    if (ble_gap_adv_active()) return;
    const auto handles = connections();
    if (handles[0] != noConnection && handles[1] != noConnection) return;
    ble_hs_adv_fields fields{};
    fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
    fields.uuids128 = &serviceUUID;
    fields.num_uuids128 = 1;
    fields.uuids128_is_complete = 1;
    int result = ble_gap_adv_set_fields(&fields);
    ble_hs_adv_fields response{};
    const char* name = ble_svc_gap_device_name();
    response.name = reinterpret_cast<const uint8_t*>(name);
    response.name_len = std::strlen(name);
    response.name_is_complete = 1;
    if (!result) result = ble_gap_adv_rsp_set_fields(&response);
    ble_gap_adv_params parameters{};
    parameters.conn_mode = BLE_GAP_CONN_MODE_UND;
    parameters.disc_mode = BLE_GAP_DISC_MODE_GEN;
    if (!result) result = ble_gap_adv_start(addressType, nullptr, BLE_HS_FOREVER, &parameters, gapEvent, nullptr);
    if (result) ESP_LOGE(tag, "Advertising failed: %d", result);
    else ESP_LOGI(tag, "Advertising started");
}
int gapEvent(ble_gap_event* event, void*) {
    if (event->type == BLE_GAP_EVENT_CONNECT) {
        if (!event->connect.status) {
            portENTER_CRITICAL(&peerLock);
            for (auto& peer : peers) if (peer.handle == noConnection) {
                peer = Connection{};
                peer.handle = event->connect.conn_handle;
                break;
            }
            portEXIT_CRITICAL(&peerLock);
        }
        if (connections()[1] == noConnection || event->connect.status) advertise();
    } else if (event->type == BLE_GAP_EVENT_DISCONNECT) {
        const auto handle = event->disconnect.conn.conn_handle;
        portENTER_CRITICAL(&peerLock);
        for (auto& peer : peers) if (peer.handle == handle) peer = Connection{};
        portEXIT_CRITICAL(&peerLock);
        BLEFrame frame;
        frame.kind = FrameKind::disconnected;
        frame.connection = handle;
        if (xQueueSend(packets, &frame, 0) != pdTRUE) {
            xQueueReset(packets);
            xQueueSend(packets, &frame, 0);
        }
        advertise();
    } else if (event->type == BLE_GAP_EVENT_SUBSCRIBE && event->subscribe.attr_handle == controlHandle) {
        portENTER_CRITICAL(&peerLock);
        for (auto& peer : peers) if (peer.handle == event->subscribe.conn_handle)
            peer.subscribed = event->subscribe.cur_notify;
        portEXIT_CRITICAL(&peerLock);
    } else if (event->type == BLE_GAP_EVENT_ADV_COMPLETE) advertise();
    return 0;
}
int access(uint16_t connection, uint16_t, ble_gatt_access_ctxt* context, void* argument) {
    const auto channel = reinterpret_cast<uintptr_t>(argument);
    if (channel == 2) {
        bool accepted = false;
        uint32_t offset = 0;
        if (context->op == BLE_GATT_ACCESS_OP_WRITE_CHR) {
            uint8_t bytes[4];
            if (OS_MBUF_PKTLEN(context->om) != 4 || os_mbuf_copydata(context->om, 0, 4, bytes))
                return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
            offset = uint32_t(bytes[0]) | uint32_t(bytes[1]) << 8 | uint32_t(bytes[2]) << 16 | uint32_t(bytes[3]) << 24;
            portENTER_CRITICAL(&peerLock);
            for (auto& peer : peers) if (peer.handle == connection) accepted = peer.descriptor.select(connection, offset, now());
            portEXIT_CRITICAL(&peerLock);
        } else if (context->op == BLE_GATT_ACCESS_OP_READ_CHR) {
            portENTER_CRITICAL(&peerLock);
            for (auto& peer : peers) if (peer.handle == connection) {
                accepted = peer.descriptor.read(connection, now());
                offset = peer.descriptor.offset();
                if (accepted && offset >= descriptorJSON.size()) peer.descriptor.eof(connection);
            }
            portEXIT_CRITICAL(&peerLock);
            if (accepted && offset < descriptorJSON.size() &&
                os_mbuf_append(context->om, descriptorJSON.data() + offset,
                    std::min<size_t>(512, descriptorJSON.size() - offset))) return BLE_ATT_ERR_INSUFFICIENT_RES;
        }
        return accepted ? 0 : BLE_ATT_ERR_UNLIKELY;
    }
    if (context->op == BLE_GATT_ACCESS_OP_READ_CHR) return 0;
    BLEFrame frame;
    frame.connection = connection;
    frame.kind = channel == 0 ? FrameKind::control : FrameKind::data;
    if (ble_hs_mbuf_to_flat(context->om, frame.bytes, sizeof(frame.bytes), &frame.length))
        return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    if (xQueueSend(packets, &frame, 0) == pdTRUE) return 0;
    ble_gap_terminate(connection, BLE_ERR_REM_USER_CONN_TERM);
    return BLE_ATT_ERR_INSUFFICIENT_RES;
}
void synced() {
    if (ble_hs_util_ensure_addr(0) || ble_hs_id_infer_auto(0, &addressType)) {
        ESP_LOGE(tag, "Could not obtain a Bluetooth address");
        return;
    }
    advertise();
}
void hostTask(void*) {
    nimble_port_run();
    nimble_port_freertos_deinit();
}
}

bool beginBluetooth(const std::string& descriptor) {
    descriptorJSON = descriptor;
    static StaticQueue_t queue;
    auto* storage = static_cast<uint8_t*>(heap_caps_malloc(32 * sizeof(BLEFrame), MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
    if (!storage) return false;
    packets = xQueueCreateStatic(32, sizeof(BLEFrame), storage, &queue);
    if (!packets || nimble_port_init() != ESP_OK) return false;
    ble_svc_gap_init();
    ble_svc_gatt_init();
    ble_svc_gap_device_name_set("OP Remote AMOLED 1.8");
    const ble_uuid128_t* uuids[] = {&controlUUID, &dataUUID, &descriptorUUID};
    for (size_t index = 0; index < 3; ++index) {
        characteristics[index].uuid = &uuids[index]->u;
        characteristics[index].access_cb = access;
        characteristics[index].arg = reinterpret_cast<void*>(index);
        characteristics[index].flags = index == 0 ? BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_NOTIFY :
            index == 1 ? BLE_GATT_CHR_F_WRITE_NO_RSP : BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_WRITE;
    }
    characteristics[0].val_handle = &controlHandle;
    services[0].type = BLE_GATT_SVC_TYPE_PRIMARY;
    services[0].uuid = &serviceUUID.u;
    services[0].characteristics = characteristics;
    if (ble_gatts_count_cfg(services) || ble_gatts_add_svcs(services)) return false;
    ble_hs_cfg.sync_cb = synced;
    ble_hs_cfg.reset_cb = [](int reason) { ESP_LOGE(tag, "Host reset: %d", reason); };
    ble_att_set_preferred_mtu(517);
    nimble_port_freertos_init(hostTask);
    return true;
}
bool readBluetooth(BLEFrame& frame) { return packets && xQueueReceive(packets, &frame, 0) == pdTRUE; }
bool notify(uint16_t connection, const uint8_t* bytes, size_t length) {
    bool subscribed = false;
    portENTER_CRITICAL(&peerLock);
    for (const auto& peer : peers) if (peer.handle == connection) subscribed = peer.subscribed;
    portEXIT_CRITICAL(&peerLock);
    if (!subscribed) return false;
    if (length > notificationCapacity(connection)) return false;
    auto* buffer = ble_hs_mbuf_from_flat(bytes, length);
    return buffer && ble_gatts_notify_custom(connection, controlHandle, buffer) == 0;
}
size_t notificationCapacity(uint16_t connection) {
    const int mtu = ble_att_mtu(connection);
    return mtu > 3 ? size_t(mtu - 3) : 0;
}
std::array<uint16_t, 2> connections() {
    std::array<uint16_t, 2> result;
    portENTER_CRITICAL(&peerLock);
    for (size_t index = 0; index < result.size(); ++index) result[index] = peers[index].handle;
    portEXIT_CRITICAL(&peerLock);
    return result;
}
void pollBluetooth() {
    uint16_t expired[2] = {noConnection, noConnection};
    portENTER_CRITICAL(&peerLock);
    for (size_t index = 0; index < 2; ++index) expired[index] = peers[index].descriptor.expire(now());
    portEXIT_CRITICAL(&peerLock);
    for (auto handle : expired) if (handle != noConnection) ble_gap_terminate(handle, BLE_ERR_REM_USER_CONN_TERM);
    static uint32_t checkedAt = 0;
    if (now() - checkedAt >= 5000 && ble_hs_synced()) { checkedAt = now(); advertise(); }
}
}