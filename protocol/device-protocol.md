# Device discovery and hardware bindings

## Identity and capabilities

Native controllers advertise the existing `_papergif-device._tcp` mDNS service.
HTTP clients read `GET /device`, a JSON
[descriptor v1](device-descriptor-v1.schema.json). Descriptor responses are
bounded to 64 KiB. `deviceID` is stable across reconnects and address changes;
`boardID` plus `hardwareRevision` selects catalog data, not a device instance.

`display: null` explicitly means no display. Screenless devices cannot advertise
media. Physical inputs have stable IDs, explicit kinds/events, and source ranges
for absolute values. Optional basic geometry is included in `layout`; it must
not refer to inputs absent from `inputs`. If geometry is omitted, clients generate
a simple screen/input arrangement. A present but invalid layout is rejected,
not silently replaced.

Runtime validators additionally enforce unique input/placement IDs, finite
coordinates, rectangles inside board bounds, increasing absolute ranges, and a
16,777,216-pixel display budget. Limits advertised in `capabilities` bound
profile size, pages, and controls; clients also enforce their own supported
profile limits. Unknown protocol versions fail explicitly.

Only a missing descriptor endpoint (`404`), followed by a valid legacy
`/status` reply identifying `paperGIF`, permits HTTP legacy-M5Paper fallback.
Malformed descriptors, timeouts, unauthorized responses, or unknown protocols
must not silently select the M5Paper adapter.

## Catalog resolution

Clients use
`https://raw.githubusercontent.com/Levi-5k/PaperRemote/main/boards/index.json`.
Match exact board ID/revision, then choose the highest package version;
ambiguous same-version matches are errors. Download only a bounded sibling JSON
filename, verify SHA-256 and schema/identity, then atomically cache it.
Redirects and arbitrary external package URLs are not accepted.

Packages supplement physical layout only. Capabilities, transport endpoints,
pairing credentials, firmware permissions, input IDs, and input value ranges
always come from the device/adapter. Keep manual overrides separate from cached
packages. Failed refreshes retain valid offline geometry and report their error.

## Negotiated profiles

`GET /remote` and `POST /remote` retain the existing transport and authentication
semantics. Use v6 for a legacy device. Use
[v7](remote-profile-v7.schema.json) only when the descriptor advertises it.
Unsupported bindings must be reported, never silently removed for downgrade.
Existing screen-control properties and action values remain unchanged.
Successful profile installation returns HTTP 200 or 201 with `{"ok":true}`;
an HTTP status alone is not proof of installation.

V7 adds a separate `hardwareBindings` array:

```json
{
  "inputID": "encoder-1",
  "event": "rotate",
  "mode": "relative",
  "action": {
    "type": "macMedia",
    "host": "",
    "text": "volume",
    "value": 50,
    "modifiers": []
  },
  "minimum": 0,
  "maximum": 100,
  "step": 2
}
```

- `action`: run the action on the named event. For `rotate`, optional
  `direction: "negative"` or `"positive"` selects counterclockwise or clockwise;
  omission selects both. Wildcard and directional bindings must not overlap.
- `relative`: add the signed encoder delta multiplied by `step` to the current
  binding value. Positive is clockwise.
- `absolute`: normalize the input's declared source range into the binding's
  minimum/maximum range, round to the nearest step anchored at minimum, and
  clamp. Half steps round away from zero.
- Minimum and maximum must be finite and increasing; step must be finite,
  positive, and no greater than the span. Intermediate arithmetic must remain
  representable.
- An input/event/direction binding is unique. A binding cannot enable a
  nonexistent push button or reference a missing input.
- The runtime owns input sampling, debounce, hold recognition, bounded
  dispatch, and value state. Loading a profile never triggers actions.
- Continuous actions require release/connection-loss cancellation. A runtime
  that cannot safely support a particular action must reject that binding at
  profile installation rather than accept and drop it later.

Keep device-session identity separate from a request's asynchronous lifecycle:
cancel/invalidate pending work on selection change, and ignore responses from
an older session. Saved profiles are isolated per native device ID.

## Reference runtime behavior

The ESP32 screenless reference accepts v6 empty-screen profiles and v7 hardware
bindings. Its physical bindings require v7. The encoder is turn-only; the button
provides press/hold/release and the slider reports 0–4095.

Relative values start at the uploaded `action.value`, not live companion
feedback, and are not persisted across reboot. An action-mode multistep encoder
event dispatches once per event; relative mode uses the signed delta. Sequence
numbers prevent duplicate/stale dispatch.

The reference supports companion-routed actions, local HTTP/WLED actions, and
BLE iPhone media commands, but it is not the complete M5Paper action engine.
Unsupported actions are rejected during upload with `unsupported_action`; do
not silently accept a binding whose runtime is unavailable. Continuous jog
cancellation on disconnect is best effort and is not a machine-safety interlock.

Its first profile must include a nonempty pairing token in `macToken` or
`computers[].token`. After enrollment, HTTP profile reads/writes require a
matching Bearer token. Credentials remain in device profile storage; BLE
enrollment retains the legacy proximity-based model rather than adding bonding.
Shared protocol fixtures contain fake addresses/tokens and are not ready-to-use
deployment configurations.

## Device controls

A device may expose its own settings, sensors and commands in the optional
descriptor `controls` array ([schema](device-descriptor-v1.schema.json)).
Clients build their control surface from this list automatically: adding a
device never requires hand-configured device controls, and a firmware update
that adds a control shows up on the next descriptor read.

| kind | value | required fields |
| --- | --- | --- |
| `toggle` | boolean | — |
| `range` | number within `minimum…maximum`, snapped to `step` from `minimum` | `minimum`, `maximum`, `step`; optional `unit` |
| `select` | one of `options[].value` | `options` |
| `action` | none; a momentary command | optional `confirm` |

`readOnly: true` marks status values such as battery or signal strength.
`group` is a display hint. `confirm: true` asks clients to confirm before
running a disruptive action. IDs are unique, stable and match
`[A-Za-z0-9._-]{1,64}`. At most 64 controls are declared.

`capabilities.transports` lists the transports the device supports (`http`,
`ble`). Clients may use any listed transport. If it is absent, assume `http`
for HTTP-identified devices and `ble` for BLE-identified devices.

`capabilities.imageTransports` optionally advertises image upload transports. It
must be a nonempty subset of `capabilities.transports`, and `imageFormats` must be
present. HTTP profile/control support alone does not imply an HTTP image API.

### HTTP Images

Native boards advertising HTTP image uploads accept `POST /images` with a raw
PIMG screensaver image or PBGI button image. Use these headers:

- `Authorization: Bearer <selected-device token>`
- `Content-Type: application/octet-stream`
- `X-Image-ID`: a canonical UUID, reused for retries of this exact upload
- `X-Image-Kind`: `screen` or `button`
- `X-Image-CRC32`: eight hexadecimal digits, CRC32 over the entire body
- `X-Image-Name`: optional printable ASCII title, limited to 48 bytes

AMOLED accepts 368x448 RGB565 PIMG (329738 bytes). PBGI has a ten-byte header:
`PBGI`, version (1 or 2), reserved zero, LE16 width, LE16 height. Version 1
stores 8-bit luminance; version 2 stores RGB565 little-endian. Dimensions are
1...540 and total payloads must not exceed 329738 bytes. Editors limit new
assets to 400 pixels per side and convert version 2 to version 1 for M5Paper.
Button controls optionally set six-digit RGB `tintHex` (text/icon),
`backgroundTintHex` and `imageTintHex`; null background/image tints inherit
the existing style. `buttonTexture.preserveColor` defaults to false. When
true, version 2 retains source colors unless an image tint is selected; fade
blends toward the chosen background. Unset background/image colors and the
default text tint retain the existing style.
The handler authorizes before receiving the body. Image/profile
uploads cannot run concurrently. New installs return HTTP 201; identical retries
return 200, with `{"ok":true,"id":"<uuid>","index":0}` (no index for button
images). Screen request IDs survive reboot in sidecar metadata; button IDs are
their immutable image identities. Reusing an ID with different bytes returns
409. Invalid data/CRC returns 400, unauthorized requests 401, busy requests 409,
full storage 507, and storage failures 500/503. Partial uploads are not installed.
Bulk upload responses close the connection; controls/profiles retain keep-alive.

`DELETE /images` uses Authorization, X-Image-ID and X-Image-Kind, with no body.
It removes only that image and returns 200 with its ID, or 404 if absent.

Identified screensaver BLE fallback uses `0x16`, LE32 length, LE32 CRC32, the
36-byte upload UUID, then up to 48 title bytes. Data and completion use the
existing `0x12`/`0x13` flow. It shares HTTP IDs, so a lost HTTP response followed
by BLE fallback does not append a second image. Clients without this advertised
capability retain legacy `0x10` uploads; button uploads retain `0x46`/`0x47`.

### HTTP

- `GET /device/controls` returns a snapshot:
  `{"values":{"slideshow":true,"sleepDelay":900}}`. Actions have no value.
- `POST /device/controls` with `{"id":"sleepDelay","value":600}` (omit
  `value` for an action) returns `{"ok":true,"values":{…}}`.
- Errors return `{"ok":false,"error":…}` with `unauthorized` (401),
  `unknown_control` (404), `invalid_value`/`read_only` (400) or `busy` (409).

Both endpoints use the same authorization as `/remote`. Messages are validated
by [device-controls-v1](device-controls-v1.schema.json).

### BLE

Commands are written to the control characteristic; replies are notified on it.

| opcode | direction | payload |
| --- | --- | --- |
| `0x50` | client → device | request a snapshot |
| `0x51` | device → client | `flags` byte, then a UTF-8 fragment of the snapshot JSON. Flag bit 0 marks the final fragment. Concatenate fragments in order. |
| `0x52` | client → device | UTF-8 set request JSON in a single write (at most 240 bytes) |
| `0x53` | device → client | `status`: 0 ok, 1 unknown control, 2 invalid value, 3 read-only, 4 busy |

A successful `0x52` is followed by a fresh `0x51` snapshot. A connection that
has requested a snapshot also receives an unsolicited snapshot when a value
changes on the device itself, so clients stay live without polling.

## Bluetooth fallback when Wi-Fi is unavailable

Wi-Fi is preferred for throughput. BLE keeps the device usable when Wi-Fi is
missing, not yet joined, or lost.

### Device → computer actions (BLE relay)

When a computer-routed action cannot be sent because the device has no Wi-Fi,
it is delivered over BLE to a registered relay instead of only being queued:

| opcode | direction | payload |
| --- | --- | --- |
| `0x70` | client → device | `role` byte (0 = the computer itself, 1 = forwarder such as a phone), then the UTF-8 computer pairing token |
| `0x71` | device → client | `status` (0 registered, 1 unknown token), then the UTF-8 computer ID |
| `0x72` | device → client | `sequence`, `flags` (bit 0 final), then a UTF-8 fragment of `{"computerId":…,"body":{…}}` |
| `0x73` | client → device | `sequence`, `status` (0 delivered, 1 failed) |

`body` is exactly the JSON the device would `POST` to the computer's `/action`.
A forwarder sends it to the computer's saved address with that computer's
token. Tokens are matched against `macToken` and `computers[].token`; one
connection can register several tokens, and registrations end on disconnect.
Direct computer relays are preferred over forwarders. Actions queued while
offline are flushed through the relay as soon as it registers. Relay-only
connections do not claim the active controller and do not keep the device
awake. When Wi-Fi returns, normal HTTP delivery resumes.

Computers connect a BLE relay only while the device is unreachable over the
LAN, and disconnect once LAN delivery works again, to preserve the device's
battery and BLE connection slots.

### Client → device

- Profile sync, device controls and media prefer Wi-Fi when the device is
  reachable over HTTP, and use BLE when HTTP is unreachable or fails with a
  transport error.
- Authorization, validation and acknowledgement failures are never retried over
  another transport.
- A Wi-Fi media upload interrupted by a transport error restarts over BLE when
  BLE is connected.
