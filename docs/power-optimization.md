# Firmware Power Optimization

PaperRemote keeps Bluetooth and home Wi-Fi available while the remote is active. Power changes must preserve button response, dynamic text, remote actions, uploads, discovery, and wake behavior.

## Implemented

- Enter ESP32 deep sleep between still screen-saver images when **Sleep Between Images** is enabled, with touch and center-button wake. Retain M5Paper v1's GPIO 2 main-power enable during sleep so timer and input wake continue to work on battery power.
- Skip Bluetooth and Wi-Fi startup on timer wakes that only advance a sleeping slideshow.
- Wait for the e-paper refresh to finish before sleeping.
- Use a 10 ms idle loop delay while retaining a 1 ms cadence for touch, uploads, animation, connection work, and Bluetooth handoff.
- Use lower-duty Bluetooth connection parameters while idle and restore the fast 15 ms interval for transfers.
- Advertise over Bluetooth at 100-200 ms intervals.
- Disable M5Paper's unused external 5 V output.
- Skip M5Unified's automatic white-screen clear at boot because PaperRemote renders the required screen itself.
- When the image screen saver is enabled, treat its wake tap only as a wake gesture. When it is disabled, leave the remote visible during idle sleep and use the wake tap as the first queued remote-control press.
- Skip the full image-library scan on normal boots and input wakes; scan on library access, playback navigation, or timer-driven slideshow wake instead.

The M5GFX e-paper driver already disables the panel's high-voltage rail after each completed refresh. Dynamic text polling also stops while the screen saver is active.

## Deferred Work

### Maximum Wi-Fi Modem Sleep

Replace `WiFi.setSleep(true)`, which selects `WIFI_PS_MIN_MODEM`, with `WIFI_PS_MAX_MODEM` while connected. This retains Wi-Fi but buffers incoming traffic according to the access point's DTIM interval.

Validate action latency, companion text updates, reconnect behavior, and multiple router brands before enabling it by default.

### Dynamic CPU Frequency

Run the ESP32 at a lower frequency while idle and restore full speed for display rendering, uploads, JSON processing, and network requests.

Measure idle current first. Validate BLE and Wi-Fi stability, touch handling, upload throughput, animation timing, and every transition that changes frequency.

### Adaptive Bluetooth Advertising

Keep the current advertising interval immediately after boot or disconnect, then use a slower interval after several idle minutes. Existing connections would be unaffected, but later discovery could take longer.

Measure the saving and set a maximum acceptable reconnection delay before changing this behavior.

### ESP-IDF Power Management

Use an SDK configuration with dynamic frequency scaling and tickless idle so the ESP32 can automatically enter light sleep between events while retaining radio connections.

The prebuilt Arduino SDK currently lacks the required power-management and tickless-idle configuration. Treat this as a toolchain migration: validate Bluetooth, Wi-Fi, timers, touch interrupts, SD access, and e-paper updates on hardware.

### SD Card Idle Power

Measure current with the SD card mounted and unmounted. If the card's idle draw is significant, add on-demand mount and unmount behavior around playback, browsing, and uploads.

Do not implement this without measurements because remount failures would affect core features and many SD cards already enter a low-power idle state.

## Measurement Checklist

Record current at the battery for each change in these states:

- Remote visible, Wi-Fi and Bluetooth connected
- Remote visible, Wi-Fi disconnected
- Bluetooth advertising with no client
- Still screen saver in deep sleep
- Animated playback
- Bluetooth and Wi-Fi uploads

Also record button-to-action latency, Bluetooth discovery time, Wi-Fi reconnect time, and battery runtime under the same workload.