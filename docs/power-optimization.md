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
- When the remote sleeps with nothing scheduled, the 60-second recovery timer wake goes straight back to sleep: no Wi-Fi, Bluetooth, or full-screen redraw. Previously each recovery wake redrew the remote and stayed awake for the whole sleep delay.
- Climate and schedule timer wakes run as background wakes. The sleeping screen stays as it is and Bluetooth stays off. Wi-Fi connects only when a command must be sent, and the device sleeps again as soon as queued work is done. A touch or button press during the wake shows the remote as a normal wake would. A scheduled iPhone action that fails starts Bluetooth and waits up to 90 seconds for the phone.
- Home Wi-Fi remembers the last access point and channel in RTC memory, so reconnects skip the all-channel scan. If the remembered access point does not answer, the cache is cleared and a full scan follows immediately. `WiFi.persistent(false)` avoids writing credentials to flash on every connect.
- Unattended home Wi-Fi retries back off from 30 seconds to 5 minutes. Any remote activity since the last attempt restores the 30-second cadence.
- Wi-Fi transmit power follows RSSI: 11 dBm at -50 dBm or better, 15 dBm down to -60 dBm, otherwise full power. The check runs every minute. Connections start at full power, and the transfer access point always uses full power.
- The CPU runs at 80 MHz when idle and switches to 240 MHz for touch, buttons, rendering, uploads, animation, and Wi-Fi transfer. It returns to 80 MHz after 3 idle seconds.
- The IT8951 e-paper controller enters standby after 2 idle seconds. A `StandbyPanel` subclass of the M5GFX panel sends `SYS_RUN` at the start of the next panel transaction.
- The SD card chip select is held high during deep sleep so the card stays deselected.
- Awake idle CPU load dropped from about 9% to under 1% at 80 MHz (measured 2026-10-04 with a temporary loop probe):
  - Schedule polling read the RTC over I2C and ran `mktime` on every loop pass, about 0.7 ms each time. It now runs once a second.
  - With no input for 3 seconds, the loop waits up to 50 ms on a semaphore instead of 10 ms. Touch, side-button, and menu-button interrupts release it immediately, so input latency is unchanged. Recent input or active work keeps the 10 ms and 1 ms cadences.
- Bluetooth advertising follows Apple's accessory pattern: 100-200 ms for 30 seconds after start or disconnect, then 1022.5-1285 ms, including while a controller is connected and the second connection slot is advertised.
- Text-source polling reuses one HTTP connection per computer. The firmware sends `Connection: keep-alive` only for these idempotent requests, and the Mac companion honors it with a silent 75-second idle close. Other clients and all error replies still close after each response.

## Low Power Mode

Turns on automatically below 30% battery and off at 35% or higher. The 5% gap keeps voltage sag during radio or panel activity from toggling the mode. The state survives deep sleep, and the remote header shows **LOW POWER** while the mode is on. Thresholds and limits are in [low_power_mode.h](../firmware/include/low_power_mode.h).

- Screen saver shows still images only, with no GIFs and no Geometric Snake. Media screen savers sleep between images.
- The screen saver and remote sleep delay is capped at 60 seconds, and **Never** is ignored.
- CPU runs at 80 MHz instead of 240 MHz.
- Wi-Fi uses maximum modem sleep (`WIFI_PS_MAX_MODEM`).
- Bluetooth advertises every 1022.5-1285 ms instead of 100-200 ms.
- Home Wi-Fi reconnect attempts run every 5 minutes instead of every 30 seconds.
- Text boxes and computer status poll at most once per minute.
- The media elapsed-time clock updates every 30 seconds. Seeks, drags, and track changes still redraw immediately.

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

## Not Implemented

Maximum modem sleep and slower Bluetooth advertising are used only in Low Power Mode, because they add latency. Dynamic CPU frequency is implemented manually (see above). Maximum modem sleep stays out of normal mode because the station sleeps through some DTIM beacons and can miss broadcast and multicast frames, such as mDNS discovery queries from the companion editors.

### Automatic Light Sleep

Not possible on this hardware and SDK while Bluetooth is running:

- The prebuilt Arduino SDK is built with `# CONFIG_PM_ENABLE is not set`, so there is no automatic light sleep or tickless idle.
- On the ESP32, the Bluetooth controller can only allow light sleep when it has an external 32 kHz crystal as its low-power clock. The M5Paper routes GPIO 32 and 33, the crystal pins, to its Grove ports, so the controller would keep the chip awake.

Revisit this only with a custom ESP-IDF build and a design that turns Bluetooth off while idle.

### Unmounting the SD Card

The M5Paper powers the SD card from the main 3.3 V rail, and the firmware cannot switch that rail off. Unmounting would not cut power. A deselected SD card in SPI mode already sits in its low-power standby state, so the only change made is holding chip select high during deep sleep.

## Hardware validation still needed

These were checked only at boot. Wi-Fi, Bluetooth, text polling over a kept-alive connection, and transmit-power trimming worked on 2026-10-04. Measure current and run long soaks for:

- IT8951 standby: confirm that every redraw after standby is correct. Check partial button feedback, text boxes, the media clock, the battery indicator, and the page after a profile push.
- Background climate and schedule wakes, including a touch during the wake.
- Recovery wakes over several hours.
- Fast reconnect after the router reboots or changes channel.

## Measurement Checklist

Record current at the battery for each change in these states:

- Remote visible, Wi-Fi and Bluetooth connected
- Remote visible, Wi-Fi disconnected
- Bluetooth advertising with no client
- Still screen saver in deep sleep
- Animated playback
- Bluetooth and Wi-Fi uploads

Also record button-to-action latency, Bluetooth discovery time, Wi-Fi reconnect time, and battery runtime under the same workload.