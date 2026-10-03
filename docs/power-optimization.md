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

## Long-idle wake investigation (2026-09-13)

Reported symptom: a library image/GIF remains visible after extended idle, and
neither touch nor physical buttons wake the device while plugged in. HTTP also
timed out during inspection. Opening the serial port reset the board, after which
the device responded again. Its saved settings were slideshow enabled, Sleep
Between Images enabled, and a 900-second screensaver delay. This reset lost the
original execution state: the exact freeze site has **not** been reproduced.

The **Images Below 100%** setting only selects still media versus animation,
sampling the battery estimate every ten seconds. It does not disable touch or
button wake, and charging by itself does not bypass the threshold. Reaching
100% may change the render workload but is not established as the freeze cause.
The battery threshold and saved settings are unchanged; diagnostics now record
mode transitions and screensaver entry.

One definite unbounded path was found in M5Unified 0.2.21 `Power_Class::deepSleep`:
with touch wake enabled, it loops until the GT911 interrupt releases, **before**
enabling the requested timer. The M5Paper implementation of
`_clearWakeupInterrupt()` returns success even when touch reads do not release
the pin, so the communication-failure escape does not bound this path. The loop
calls `M5.update()` but never the application's button/touch/HTTP handlers. A
stuck-low IRQ can therefore leave the screen asleep with neither responsive
controls nor a running recovery timer. This is a confirmed code defect and a
candidate explanation, not a confirmed diagnosis of the original freeze.

Firmware now uses [sleep_wake.h](../firmware/include/sleep_wake.h) to bound the
release wait to 250 ms and cancel sleep on an active touch or side button. A
failed attempt returns to the main loop and defers retries; stuck-line reports
are rate-limited and queued to companion diagnostics. EXT0 touch and EXT1 center
button wake are explicitly armed before calling `M5.Power.deepSleep(..., false)`.
Passing `false` skips only the library's touch-release setup, not the already
armed EXT0 source. Existing timer selection and GPIO 2 power hold remain intact.
A new touch after the release check can cause an immediate wake rather than
trap sleep entry. No installed dependency source was modified.

[sleep_wake_test.cpp](../firmware/tests/sleep_wake_test.cpp) covers stuck IRQ,
normal release, held touch/button, a button during the wait, subsequent recovery,
and clock rollover. The firmware host tests and M5Paper build passed and the
image was flashed. A passive serial capture is left open for the long-idle soak;
it sends no device commands or HTTP keepalives. A short reboot check does not
establish that the reported long-duration issue is resolved. Post-flash capture
reported a 10-second delay, media style, 30-second image interval and **Images
Below 100% off** (changed externally; this patch does not write settings). Thus
the 100% policy is not active in the current test. HTTP and a real user button
action succeeded after the flash. At 23:10:25 UTC the new firmware displayed a
single-frame image and armed scheduled deep sleep with battery reported at 100%.
All nine host test programs passed. Restore the preferred delay after testing;
long-duration sleep and center-button/touch wake validation remain outstanding.

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