# Windows custom controllers

The Windows companion supports the native PaperRemote HTTP protocol and verified
legacy M5Paper firmware. It does **not** configure arbitrary third-party products.
Such products need an explicitly implemented `IDeviceAdapter`; board catalog JSON
is data, not an executable driver or protocol adapter.

## Connect and configure

1. Select a discovered controller, a saved controller, or enter its HTTP(S) address
   (including a nonstandard port) in **Hardware**, then choose **Connect**.
2. The companion reads and validates `GET /device`. Only a **404**, followed by a
   successful `/status` reporting exactly `"device":"paperGIF"`, permits the
   legacy adapter. Timeouts, invalid JSON, unsupported versions, authentication
   failures, and server errors never identify an unknown device as an M5Paper.
3. A descriptor-provided layout is immediately usable. If the `layout` key is
   absent, the companion generates bounded screen/input geometry before
   validation, using the same generated layout policy as Swift. An explicitly
   null or invalid layout is rejected rather than replaced. The `display` key
   remains required, including explicit null for screenless devices.
   The companion loads an
   exactly matching cached/bundled layout, then automatically checks
   `https://raw.githubusercontent.com/Levi-5k/PaperRemote/main/boards/index.json`.
   Board ID **and** hardware revision must match exactly. Package SHA-256,
   version, bounded JSON geometry, and known input IDs are checked. No scripts,
   arbitrary URLs, or capability overrides are accepted. Network failures leave
   the last valid preview intact; the Hardware panel shows the outcome and retry.
4. Select a physical input in the preview or Hardware input list, select an event,
   and choose **Assign**. Expand **Action** in the property inspector to configure
   the existing companion/network action fields. Computer actions use the
   selected computer ID/token in that device's profile.

Bindings are independent of touchscreen page controls. Buttons support their
advertised press/hold/release events; encoders support signed relative adjustment
or separate left/negative and right/positive actions. Leave direction empty for
an action on both directions. A wildcard and directional action cannot overlap.
Absolute dial/slider mapping uses the device-reported input range. Adjustment
requires a value-capable action, a finite output range, and a positive step.
Preflight permits volume (`text: volume`) within 0–100, WLED brightness within
0–255, and NetHome temperature within −3276.8–3276.7 (Int16 tenths). Other
actions cannot use relative/absolute adjustment.
Continuous jogging is deliberately unavailable for hardware bindings: a lost
release must not leave a machine moving.

A screenless device shows physical geometry only, with no pretend touchscreen.
New native devices start with an empty page; use physical bindings. Profiles
containing touchscreen controls cannot be sent to a screenless/non-touch device.
**Clear screen controls** is an explicit, confirmed operation on the selected
profile. Catalog refresh never changes actions, capabilities, or mappings.

## Profiles, manual geometry, and offline behavior

Profiles and their Wi-Fi/computer credentials are saved separately by stable
device ID in `%LOCALAPPDATA%\paperGIF\remote-editor.json`. Legacy firmware without
a stable identity is address-scoped; its original single-device document is
preserved. Moving an address-scoped legacy device to a new address cannot safely
infer that it is the same physical device. The original profile remains saved.

Switching devices cancels/invalidate pending profile/catalog work. Discovery and
update checks do not silently switch to another controller. Profiles use
`GET /remote` and `POST /remote`; payload version is negotiated from the
descriptor. Legacy firmware receives v6 without a `hardwareBindings` field.
Native v7 receives a distinct `hardwareBindings` array. Unsupported mappings or
device capacity/byte limits block upload instead of silently dropping content.
Profile installation (including legacy `/remote/controls`) requires HTTP 200 or
201 **and** JSON `{"ok":true}`. A successful HTTP status with `ok:false`, an empty
body, or malformed acknowledgement never advances the installed-profile state.

Saved validated descriptors permit offline previews/editing. Writes always
re-identify the endpoint. **Import layout JSON** and **Edit layout geometry** accept
only a descriptor-layout object; input IDs and display presence must match the
device. Manual overrides are separate from cached catalog packages and survive
catalog refresh. **Use automatic layout** removes only the manual override.

## Media and firmware boundaries

Display dimensions, orientation and touch availability drive the preview without
allocating a full-resolution device framebuffer. Generic displays use the same
4% inset/92% normalized page grid and two-preview-point control gap as the Mac
editor; drag/drop and hit testing use those same cells. M5Paper retains its
explicit legacy layout, including OpenBuilds settings.
Custom-panel media conversion
and upload are not implemented. Screenless devices cannot use display media;
button image assets remain restricted to the known M5Paper media format. Media
playback actions (for example computer volume) are not display media and remain
usable by physical inputs.

The existing firmware release asset is for `m5stack.m5paper`, revision `1.0`.
Only an identified compatible device advertising firmware updates can receive
it. Identity/compatibility are rechecked after download; custom boards cannot be
offered this binary. No automatic catalog firmware/driver installation exists.
The binary must contain the exact embedded
`PGIFBOARD:m5stack.m5paper@1.0;` marker before the Windows client uploads it.
Unmarked older assets are rejected too. The existing OTA transport sends bearer
authorization, multipart content, `X-PGIF-Size`, and `X-PGIF-MD5`; board identity is
in the compiled binary, not an overrideable board-name header.

The ESP32 screenless target is a **reference** integration. No physical custom
reference hardware was available for validation. Core protocol/catalog tests run
cross-platform; Windows UI projects can be cross-built on macOS with
`EnableWindowsTargeting=true`, but WinForms interaction and hardware behavior
still require Windows and representative devices.

## Device controls and Bluetooth fallback

A descriptor may declare an optional `controls` array (see "Device controls" in
`protocol/device-protocol.md` and `protocol/device-controls-v1.schema.json`) and
optional `capabilities.transports` (`"http"`, `"ble"`). Both are optional and are
preserved when the companion round-trips a descriptor. Without `transports`, the
transport the device was identified over (HTTP) is assumed.

- **Validation.** Descriptors are rejected when controls break the spec: ids must be
  unique and match `^[A-Za-z0-9._-]{1,64}$`; there can be at most 64 controls; a
  `range` needs `minimum < maximum` and `0 < step <= span`; a `select` needs 1–32
  options with unique values; an `action` must not have `readOnly`, `options` or
  `minimum`. Range values are snapped to `step`, anchored at `minimum` and clamped.
  Select values must match an option, and toggles must be booleans.
- **Device tab.** The editor's **Device** tab is built automatically from the
  selected device's controls and grouped by `group`:
  - toggle → checkbox
  - range → slider plus numeric box with its unit
  - select → drop-down
  - `readOnly` → label
  - action → button, with a confirmation dialog when `confirm` is true

  The tab reads a snapshot when a device is selected and polls every 3 s while it
  is visible. Changes are sent with `POST /device/controls` using the same Bearer
  token as `/remote`. The tab reverts to the device-reported value and shows the
  error if the device rejects a change. Responses are capped at 64 KiB and
  requests time out after 5 s.
- **Bluetooth fallback.** When `transports` includes `ble` and HTTP fails with a
  *transport* error (timeout, refused, unreachable), the tab retries over BLE:
  - It uses service `7A230001-7D2A-4C7B-9C42-504749460001` and control
    characteristic `7A230002-…` (frames `0x50`–`0x53`).
  - The device is identified by reading its descriptor and checking `deviceID`.
  - Device rejections (`unknown_control`, `invalid_value`, `read_only`,
    `unauthorized`, …) are never retried on another transport.
  - BLE pushes live snapshots. The connection is released once HTTP works again.
- **Action relay.** While the selected BLE-capable device has been unreachable
  over the LAN for 20 s (`GET /device` probe every 10 s), the companion:
  - connects over BLE and registers as relay role 0 (`0x70`) with this computer's
    pairing token, the `Token` in `%LocalAppData%\paperGIF\windows-companion.json`;
  - runs each reassembled `0x72` body through the same handler as `POST /action`;
  - acknowledges with `0x73`. Status is 0 when handled, and 1 when the body is
    malformed, failed, or addressed to another computer.

  It disconnects once the LAN probe succeeds again. After a registration
  rejection it waits 5 minutes before retrying; other failures wait 30 s.

Limitations:
- **The BLE/WinRT code (`WinRtBleConnector`, `BleRelayService`) has not been run
  on Windows hardware.** It is compiled by cross-building on macOS, and its
  protocol logic is tested only against fakes (codec, session, pool and relay
  coordinator in `DeviceControlTests`).
- BLE does not use bonding. Before sending the token, the companion only checks
  that the peripheral's descriptor `deviceID` matches the paired device, so a
  peripheral that spoofs that descriptor could capture the token.
- The LAN health check is the HTTP `/device` probe; the mDNS state is not
  consulted. Over Wi-Fi, values that change on the device are picked up by
  polling, not pushed.

## Reproducing validation

Run from the repository root with .NET SDK
`11.0.100-rc.2.26504.105` (the SDK used for validation) or a compatible .NET 11 SDK:

```sh
dotnet test windows-companion/tests/PaperGIF.Windows.Core.Tests/PaperGIF.Windows.Core.Tests.csproj \
  --filter 'FullyQualifiedName~CustomDeviceTests|FullyQualifiedName~RemoteProfileContractTests|FullyQualifiedName~DeviceControlTests' \
  --verbosity quiet
dotnet build windows-companion/tests/PaperGIF.Windows.Host.Tests/PaperGIF.Windows.Host.Tests.csproj \
  -p:EnableWindowsTargeting=true --verbosity quiet
```

The second command compiles both the Host application and its tests. Final
validation uses the projects' unchanged `net11.0` and
`net11.0-windows10.0.22621.0` targets; **no target-framework override** is required
or used. .NET 10 cannot build these targets. The locally provisioned SDK and
install script were validation scratch and are not part of the repository.
