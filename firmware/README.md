# Firmware reference targets

`m5paper-v1` retains the M5Paper renderer and profile v6 support.
`esp32-screenless-reference` is an unvalidated ESP32 development-board reference,
not a claim of tested physical hardware support.

## Screenless initial storage provisioning

The normal reference firmware mounts LittleFS **without formatting**. A blank or
corrupt filesystem remains untouched. Serial output reports the failure, `/status`
reports `ready:false`, and HTTP profile installation returns 503
`{"error":"storage_unavailable"}`. BLE profile installation also fails.

For a new board, or after consciously deciding to erase damaged storage:

1. Build and flash the **explicit destructive opt-in**:
   ```sh
   pio run -d firmware \
     -e esp32-screenless-reference-provision -t upload
   ```
2. Boot it and watch Serial at 115200 baud. If mounting fails, it prints
   `DESTRUCTIVE OPT-IN: formatting LittleFS after mount failure; existing profiles will be erased.`
   before formatting. A successfully mounted filesystem is never reformatted.
3. Flash the normal, non-formatting firmware **before enrolling credentials**:
   ```sh
   pio run -d firmware \
     -e esp32-screenless-reference -t upload
   ```
   Do not erase flash between these steps. Do not leave the provisioning build
   installed: it would also erase a previously used filesystem on a later mount failure.

Equivalent custom builds may explicitly define
`PAPERGIF_REFERENCE_FORMAT_ON_MOUNT_FAILURE=1`; its default is `0`.

Join AP `op-remote-XXXX` (MAC suffix), password `paperdisplay`. Serial prints its IP
(normally 192.168.4.1). Submit a v7 profile using JSON `POST /remote` through that
AP. Include a nonempty `macToken` or computer token; optional `wifiSSID` and
`wifiPassword` provision station Wi-Fi. Success is HTTP 201 `{"ok":true}`. The AP
stays enabled. Later HTTP GET/POST `/remote` requires a matching
`Authorization: Bearer <token>`. Profiles, credentials, and tokens are stored in
plaintext LittleFS `/remote.json`, with staged `/remote.new` and `/remote.bak`.

Compiled input defaults: `PAPERGIF_BUTTON_PIN=25` (active-low pull-up),
`PAPERGIF_ENCODER_A_PIN=26`, `PAPERGIF_ENCODER_B_PIN=27`, and
`PAPERGIF_SLIDER_PIN=34` (ADC1, raw 0–4095). No encoder push or display is wired.
BLE enrollment has no added authentication or bonding enforcement.

The `supermini-s3-mt6701` target uses an ESP32-S3 SuperMini with two active-low
pull-up buttons and an MT6701 absolute dial: GPIO10/11 are Button 1/2, and
GPIO13/12 are I2C SDA/SCL. The dial reads the MT6701's 14-bit angle at I2C
address `0x06` and advertises `dial-1` from 0 to 16383. Build with
`pio run -d firmware -e supermini-s3-mt6701`. Its explicit
`supermini-s3-mt6701-provision` variant formats LittleFS only after a mount
failure; use that only for intentional first-time provisioning, then install
the normal target without erasing flash.

The `waveshare-amoled-18-v2` target is the same knob and two buttons on a Waveshare
ESP32-S3-Touch-AMOLED-1.8 V2 (368×448 CO5300, CST820 touch, LVGL 9.6). Buttons are
active-low pull-ups on GPIO17 and GPIO18. The MT6701 stays at I2C `0x06`, on the
board bus SDA GPIO15 / SCL GPIO14 — SuperMini SCL GPIO12 is this panel's chip select.
Its primary firmware is now **native ESP-IDF 6.1**, built from the repository root.
The PlatformIO `waveshare-amoled-18-v2` environment is retained as a legacy Arduino
fallback; other board environments remain unchanged.

## Native AMOLED build

Select ESP-IDF **v6.1** and target **esp32s3** in the VS Code ESP-IDF extension,
then use **ESP-IDF: Build your project** and **ESP-IDF: Flash your project**.
With Espressif Installation Manager, the equivalent commands from repository root are:

```sh
eim run "idf.py build" v6.1
eim run "idf.py -p /dev/cu.usbmodem14101 flash monitor" v6.1
```

The root CMake project uses `firmware/idf/main`, configuration defaults in
`firmware/idf/sdkconfig.defaults`, and the checked-in dependency lock. The binary
is `build/paperremote_amoled.bin`. This target uses native NimBLE, Wi-Fi station,
HTTP client/server, NVS, I2C, SPI, and FreeRTOS APIs. ArduinoJson is a standalone
C++ dependency, not an Arduino core. LVGL 9.6 and LittleFS remain shared libraries.

Bluetooth retains the app's service UUIDs, device identity, acknowledged profile
upload, device controls, and companion relay protocol. The device never starts
an access point. Setup is through Bluetooth; saved home Wi-Fi enables the same
HTTP endpoints and `_papergif-device._tcp` discovery. The iPhone learns the native
device's current IP from its Bluetooth Wi-Fi status, verifies `/device` against
the selected device ID and advertised HTTP capability, and saves the verified
address with that device. Selection and periodic connectivity checks retry saved
addresses; a new DHCP address replaces the saved address only after verification.
Profiles and controls prefer verified HTTP using the selected device's Keychain
token. Reachability failures can fall back to Bluetooth; authorization and device
rejections do not retry the same request over another transport. Bluetooth stays
connected for live dial events, relay traffic, and native library operations.
Native screensaver/button images prefer the authenticated HTTP image API when
advertised, with identified Bluetooth fallback on transport failures. The M5Paper's home Wi-Fi and
setup-access-point paths remain separate. Profiles retain swipeable
tile pages and page-scoped knob/button bindings, including low-latency dial output.
Physical buttons and the dial are sampled by a dedicated 1 ms native task.
On pages with an active knob-to-slider binding, the knob automatically emits
relative movement instead of absolute shaft positions. It adjusts the current
slider value without a pickup jump or physical end stops; saved dial settings
are unchanged. Seek starts from live playback when no recent local seek is pending.
Mutex-protected event handoff preserves button ordering, coalesces absolute knob
positions, and accumulates relative knob motion. Queue overflow cancels active
inputs rather than risking a lost release; diagnostics expose dropped events,
sample count, and sampler stack headroom. Dial/touch I2C transactions are serialized.
Native knob bindings use companion UDP streaming automatically, with a 500 updates/s
ceiling unless a custom low-latency rate is enabled. DNS, socket writes, pacing,
and the final-value retry run on a separate network worker, not the LVGL task.
Actual output is change-only and limited by binding step, UI dispatch, and transport
throughput. Button commands cancel stale knob retries. Profiles and LVGL remain
main-task owned; workers receive copied requests. Other actions retain HTTP/BLE.
Page transitions follow the finger in the same refresh. Adjacent pages stay built
so the first movement does not rebuild tiles, and release eases into place. A quick
flick commits without crossing the full distance threshold. Short or reversed drags
return to the current page; slider drags remain independent. LVGL uses a 256 KB PSRAM pool to render the visible page and its neighbor together.
All slider tiles use the whole tile as a horizontal fill and touch surface,
without a separate track or knob. Titles and values remain visible with
contrasting text over the filled area; optional slider outline insets are retained.
Refresh and touch polling target 16 ms. Two full-screen PSRAM draw buffers
(659456 bytes total) overlap rendering with a dedicated transfer worker at the
vendor-specified 40 MHz QSPI clock. LVGL redraws only invalidated areas so button
highlights and value changes do not force a full-screen redraw. Full-screen draw
buffers still accommodate large swipe updates without the former 48-row splits;
two internal 16-row DMA staging buffers (23552 bytes total) overlap byte swapping
with queued transfers while keeping chip select asserted for the pixel stream.
LVGL waits for completion before reusing the submitted frame buffer. Only the
main task accesses LVGL objects. The vendor V2 pin map exposes no TE GPIO, so this
reduces upload gaps but does not guarantee scan-synchronized, tear-free output.
Authenticated `/debug/inputs` display diagnostics include the buffer sizes, bus
clock, full-frame mode, and free internal memory.
Serial `AMOLED perf` samples report completed refreshes per sampling window,
transfer microseconds per refresh, and average/maximum UI poll duration (including
transfer waits). Measure during continuous swipes: idle and partial updates are
not a full-screen FPS benchmark, and the 16 ms target does not guarantee 60 FPS.
Profile syncs that name the current Wi-Fi network without a password retain the
Bluetooth-provisioned password. Explicit profile credentials are saved in NVS
for later syncs and restarts, so editing tiles does not disconnect WLED controls.

Media seek tiles use full-tile progress with contrasting track text, optional
outline inset, and the profile's text size/alignment. The header shows elapsed
and total time; scrubbing commits once on release.
Hardware-bound seek changes update the fill and elapsed time immediately, with
the same stale-echo protection as touch scrubbing.
Changes to the reported track title, duration, or availability reset the pending
seek preview and relative-knob baseline together, without waiting for the old
track's echo timeout.
Seeking to 100% on a fresh, playing track sends a one-shot Next command instead
of relying on the player's reported duration to trigger track completion.
This endpoint command bypasses knob-stream retries; paused and partial seeks
keep their normal position-seek behavior.
Desktop state is fetched from the selected companion's `/text-source` endpoint in a separate bounded worker,
with authenticated `/text-source/update` pushes and local timeline progression.
Each computer has its own cache; profile changes and media commands invalidate
older replies. iPhone playback uses BLE state packet `0x61`. Unknown-duration
media cannot be scrubbed, and stale timelines stop advancing. Authenticated
`/debug/inputs` includes playback diagnostics.

The native descriptor advertises `imageFormats: ["pimg-rgb565-v1", "pbgi-gray8-v1", "pbgi-rgb565-v2"]`. The iPhone
Media tab uses the same Phone/Device library, saved-media cards, Crop/Fit editor,
zoom, rotation, Save, Export and Send workflow for both displays. Original sources
and recipes stay in the phone library so sends can be converted for the selected
screen. M5Paper retains its grayscale image/GIF path; AMOLED sends still colour
images over HTTP when verified, otherwise acknowledged Bluetooth. Other RGB565 screens
must explicitly implement and advertise this format before the app enables it.

`PIMG` v1 is a 10-byte header: ASCII magic, version `1`, reserved `0`, width and
height as UInt16 little-endian, followed by tightly packed RGB565 little-endian
pixels. AMOLED requires exactly 368x448. Upload uses media commands `0x10`/`0x12`,
CRC32 and the existing progress/completion acknowledgements. Images append to the
library. The HTTP `POST /images` API and identified BLE `0x16` uploads share
persistent retry IDs; see `protocol/device-protocol.md` for headers and errors.
HTTP installs validate the full body and CRC before committing, authorize before
body reception, and acknowledge the matching ID only after persistence. Button
images use the same API with `X-Image-Kind: button`. `DELETE /images` removes an
image by ID. Bulk HTTP transactions close their connection, avoiding interference
with control/profile keep-alive. The authenticated `/debug/inputs` imageHTTP
object reports the last upload stage, received bytes, and Expect header state.
Images append to the
library; a full library rejects uploads rather than overwriting images. The Device
library uses the existing `0x20`/`0x22` list, `0x25` display and `0x23` delete commands.
Successful sends display the new image immediately. Device
settings expose screensaver enable, idle delay, image interval, Show images, and
Clear screensaver images. Touch/button/dial activity wakes the remote; the first
wake input does not activate a control. Default idle delay is 60 seconds.

The descriptor's optional `capabilities.mediaStorageID` is an opaque mount-session
identity, refreshed on boot. Clients invalidate cached button upload
acknowledgements when it changes, including after card replacement.

The V2 microSD socket uses native 1-bit SDMMC: CLK GPIO2, CMD GPIO1, D0 GPIO3,
with TCA9554 output 7 high, matching Waveshare's V2 SD example. Insert a FAT32 card
with power off, then restart. Cards mount without formatting at `/sdcard`; media
and button assets use its `/paperGIF` directory. The SD library supports 128 images
and loads only the displayed image into PSRAM. Without a mountable card, the device
uses its existing four-image internal LittleFS library. These are separate libraries;
card insertion does not move or erase internal images. Remote profiles and connection
settings always remain internal. Device settings > Storage shows card mount status,
capacity and the active image limit. Power off before removing the card; hot swapping
and exFAT are not supported. Unrelated files and existing M5Paper media are left alone.

Button backgrounds support inherited/per-button styles, patterns and cropped
`PBGI` images through `0x46`/`0x47`. The app uploads referenced images before
syncing the profile. Uploads use bounded PSRAM buffers and staged file replacement;
CRC/format errors, disconnects and timeouts preserve installed images and profiles.

`firmware/idf/partitions.csv` matches the legacy 16 MB layout exactly. Normal
flashing does not erase NVS or the `spiffs`-labelled LittleFS partition. Existing
profiles and the `papergif-dial` / `papergif-wifi` namespaces are reused. Mount
failure never triggers formatting. A genuinely blank board can first use the
legacy `waveshare-amoled-18-v2-provision` opt-in, then be flashed with native IDF
without erasing flash. Do not run `erase-flash` to resolve a mount failure.

## Descriptor BLE reader ownership

Service `7A230001-7D2A-4C7B-9C42-504749460001`, READ|WRITE descriptor characteristic
`7A230004-7D2A-4C7B-9C42-504749460001`:

1. Claim the reader by writing exactly `00 00 00 00` (offset zero, UInt32LE),
   with response. An initial read without this claim is rejected.
2. Read raw JSON slices of at most 512 bytes. For each subsequent slice, write
   its UInt32LE offset, then read the characteristic. Offset 512 is
   `00 02 00 00`. ATT Read Blob supports each slice on smaller MTUs.
3. Concatenate bytes before UTF-8 decoding. There is no envelope or NUL.
4. **After the final short nonempty slice, explicitly write an offset at or
   beyond the total JSON byte count and read the empty value.** This releases
   the lease. An exact multiple of 512 likewise ends with an empty EOF read.
   Alternatively disconnect.

A short nonempty slice cannot release storage immediately: it may still have
pending Read Blob continuations. One connection owns the cached value throughout
the transfer. Competing, unclaimed, malformed, or expired requests disconnect the
requesting connection without replacing the owner's cached slice. NimBLE's void
callbacks do not expose a custom ATT busy status. Each accepted offset write/read
renews a 30-second idle lease. Expiry disconnects the owner, and takeover remains
blocked until its disconnect callback confirms release. HTTP GET `/device`
remains public and does not acquire this lease.

The native AMOLED target instead keeps an immutable descriptor with one lease
per connection, allowing the phone and a companion to read independently.
Invalid requests return an ATT error; an expired lease disconnects its owner.

## Device controls and Bluetooth relay

Both firmwares declare `controls` and `capabilities.transports` in `/device`
(tables in `include/m5paper_controls.h` and `include/reference_controls.h`; shared
validation, snapshot, fragmentation and relay registry logic in
`include/device_controls.h`). Controls are read and set with authenticated
`GET`/`POST /device/controls` or BLE `0x50`–`0x53`. A `0x50` request subscribes
the connection to unsolicited `0x51` snapshots when values change on the device.
BLE packets are queued from the NimBLE callback and handled on the loop task.

Companions may register a relay with `0x70` (token checked against the profile
computers). While Wi-Fi is down, computer-routed actions are sent as `0x72`
frames (a direct computer relay is preferred over a forwarder). If Wi-Fi is up but
the TCP connect to the computer fails, the action is retried once over a direct
relay. The M5Paper also flushes its offline action queue through a newly
registered relay. Relay-only connections never become the active controller and
do not keep the device awake.

## Validation

From repository root:

```sh
bash firmware/tests/run_custom_board_tests.sh
pio run -d firmware \
  -e m5paper-v1 -e esp32-screenless-reference \
  -e esp32-screenless-reference-provision
```

Host tests use AddressSanitizer/UndefinedBehaviorSanitizer and shared protocol
fixtures. When `.venv` has `jsonschema`, the emitted descriptors and control
messages are also validated against the protocol schemas. Physical flashing, electrical behavior, concurrent radio connections,
and CoreBluetooth Read Blob behavior require hardware validation.
