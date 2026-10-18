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

Join AP `papergif-XXXX` (MAC suffix), password `paperdisplay`. Serial prints its IP
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
