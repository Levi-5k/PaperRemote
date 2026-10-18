# Custom controller devices

PaperRemote separates the **controller board** you configure from action targets
such as a WLED light, Shelly relay, or computer. Adding a controller does not
automatically make every network accessory a configurable remote.

## Adding a controller

Use the Device setup controls in the iPhone/iPad app or desktop editor. Select a
discovered controller, or enter its hostname/IP address and optional port.

New controllers are discovered two ways:

- **Wi-Fi:** Bonjour (`_papergif-device._tcp`) and local-subnet `/status` probes
  on the Mac and Windows editors.
- **Bluetooth:** every app scans for the PaperRemote BLE service, so a fresh
  board that is only on its own setup access point still shows up. On the phone,
  Device setup → **Nearby Bluetooth Devices** lists each board with its signal
  strength. Tapping **Connect** reads its descriptor and saves it under
  Controllers. In the Mac and Windows device pickers these boards appear as
  "Name (Bluetooth)", and selecting one reads its descriptor so the layout and
  device controls are available. Desktop editors can send profiles only after
  the board joins Wi-Fi (set its network from the phone's **Device → Device
  Setup, Wi-Fi & Saved Controllers → Wi-Fi Setup**); until then, Send is blocked
  with an explanation.

To join a SuperMini/reference controller to Wi-Fi, select it in Device Setup
(or connect to it under Nearby Bluetooth Devices). The **Wi-Fi** section asks
the board to scan with its own radio and lists the networks it can reach, with
signal strength and a lock for secured networks. Tap a network, enter only its
password, and tap **Join**; use **Other Network…** for hidden networks. The
board saves the network, reconnects automatically after restarts, and the
section shows live status: joining, connected with its IP address, or why it
failed (wrong password, network not found / not 2.4 GHz). Joining the board's
setup access point is not required. A board that already has a profile accepts
a new network only from a phone holding that profile's token (the phone
registers automatically); otherwise use **Send Saved Profile** first. The
network is also saved in the phone's profile for the board, and a profile that
names a different network replaces the one chosen from the list. First-time
enrollment generates a token only if the profile has no existing enrollment or
paired-computer token. The M5Paper keeps its existing Wi-Fi Setup flow.

Selecting a saved controller reconnects by stable device ID, even if it was
saved before Bluetooth peripheral mappings were introduced. Other nearby boards
are not substituted for the requested controller. Desktop discovery requires an
updated installed companion, not only updated source code.

1. PaperRemote reads the controller's identity, display, physical inputs,
   capabilities, and basic layout.
2. You can use its device-reported layout without an internet connection.
3. The app automatically checks the
   [curated board catalog](../boards/index.json) on GitHub for an exact board ID
   and hardware-revision match. A matching, validated JSON package supplements
   the preview; it cannot change capabilities or execute code.
4. Bundled and previously downloaded layouts remain available offline. Catalog
   failures are shown in setup and do not erase a usable layout.
5. Each saved controller has its own profile. Changing an IP address must not
   change a native controller's identity or transfer another board's mappings.

Older M5Paper firmware remains supported through the existing protocol. Its
fallback identity is tied to the saved network endpoint or BLE peripheral until
firmware exposes a stable device ID. Firmware without a descriptor is recognized
only through the known legacy protocol, not by guessing from a product name.

On iPhone/iPad, native controllers advertising BLE and profile version 7 can
receive profiles (including Wi-Fi settings) over the negotiated `0x40` BLE
transfer. Device controls use the shared BLE control protocol, independently of
the M5Paper adapter. Loading a native profile still requires its HTTP endpoint.
M5Paper-only media, image, Wi-Fi-scan, and phone-local action commands remain
disabled for other boards.

## Screens and physical controls

Descriptors specify a logical screen size rather than assuming 540 x 960.
Portrait, landscape, square, and small screens can be described. One screen per
controller is supported by this contract. Rotation is panel metadata; width and
height describe the already oriented logical viewport.

A screenless controller uses a physical board preview and input assignments, not
an invisible touchscreen. Its profile still contains an empty `Main` page for
wire compatibility, with assignments in `hardwareBindings`.

Supported physical input descriptions are:

| Input | Events | Binding behavior |
| --- | --- | --- |
| Button | press, hold, release | Assign an action to each supported event |
| Relative encoder | rotate; optional press/hold/release | Clockwise/counterclockwise actions, or signed value adjustment |
| Absolute dial | change | Map the device's position range to an action value |
| Slider | change | Map the device's position range to an action value |

The device must advertise optional events: a turn-only knob does not acquire a
push button because a catalog picture contains one. Value bindings have explicit
minimum, maximum, and step settings. Only actions that actually accept values
may use relative/absolute modes. For example, use volume, brightness, or target
temperature, not “next track,” as an adjustable value.

### SuperMini MT6701 live dial

Updated SuperMini firmware exposes a **Live dial** surface on iPhone/iPad, Mac,
and Windows. Reconnect/refresh discovery after flashing so the
apps read the new descriptor. The needle shows the sensor's shaft angle; the
position and revolution readouts show the tracked, filtered travel. BLE pushes
changed snapshots at most 10 times per second; visible Wi-Fi views poll every
200 ms, without polling BLE at that rate.

- **Bounded single turn:** choose a start angle and 1–360 degrees of travel.
  Drag the green Start and orange End handles, or enter exact numeric values.
  Drag End past Start to put the end stop on the other side: the end stop is
  stored as a signed value (negative = counterclockwise), so turning toward the
  End stop always increases the output.
  Crossing the sensor's 359-to-0-degree boundary does not jump the output.
- **Bounded multi-turn:** choose 0.1–100 revolutions from minimum to maximum;
  a negative revolution count puts the end stop counterclockwise of Start.
  The progress indicator shows travel between the stops; adjust the revolutions
  field/slider to move the end stop.
- **Continuous relative:** clockwise/counterclockwise movement increments or
  decrements the existing value binding. Revolutions per output range sets
  sensitivity; there are no angular stops. The assigned action's own minimum
  and maximum still apply.
- **Sensing:** the full 14-bit MT6701 angle (16,384 counts per turn) is read
  about every millisecond, and every reading within an output period (5 ms, or
  one send period in low latency mode) is averaged, wraparound-safe, into a
  single sub-count position. Nothing is sent while the averaged position is
  still; the settled position after movement is always sent.
- **Precision:** Output resolution is 0.01–10% of the assigned output range
  (default 0.01%).
  The binding's existing Step is the final output-unit increment (for example,
  volume percentage points). Sub-step relative movements accumulate rather than
  being discarded. Jitter filter is 0–5 degrees of angular hysteresis (default 0.05,
  applied after averaging); slow
  deliberate movement is retained. Older firmware's "reverse direction" setting
  is migrated to a negative end stop.
- **Set current position to start** calibrates the origin to the current shaft
  angle. Configuration is stored on the device and survives restart. Changing
  modes, origin, or direction reinitializes travel; changing precision, filter,
  or the end limit preserves it (clipping to a shortened range when necessary).

On the phone, the dial settings appear only in the knob's own settings: on the
Remote page, tap the knob (or its row) and open **Configure Dial**. The knob on
the Remote page's board preview turns with the live shaft angle. The Mac and
Windows apps show the settings view in the device's Controls.

When the knob has no Wi-Fi, actions are relayed over Bluetooth. The firmware
coalesces relayed slider/volume values (latest value wins, at most every 40 ms)
so the computer never falls behind; the Mac sets volume directly via CoreAudio
rather than spawning a script per tick. The Mac connects straight to a
Bluetooth-only knob (no IP address required) once the knob's profile includes
that computer.

**Low latency mode** (Configure Dial) sends only dial *changes* at a fixed
rate of 15–500 per second (default 75). The sensor is sampled at least that
often; the newest value always wins, and one repeat is sent after the dial
stops so a dropped final packet cannot leave the target stale.

- Computers on Wi-Fi receive the dial as UDP datagrams on their action port
  (default 43821) instead of one HTTP request per change. Stale or reordered
  datagrams are discarded. Releases, safety events, and button actions still
  use HTTP. Without Wi-Fi the knob falls back to the Bluetooth relay.
- The phone receives compact 7-byte live-dial notifications at the same rate,
  so the preview and iPhone media actions follow the dial closely.
- Higher rates use more radio time and battery; 75 per second is smooth for
  volume and similar controls.

These are **software end stops**, not motorized/haptic stops. Excess rotation
at a limit is discarded so reversing responds immediately. The MT6701 is a
single-turn absolute sensor: multi-turn travel is retained while running, even
across BLE/Wi-Fi disconnects, but cannot be reconstructed after power loss or
while the sensor is disconnected. Multi-turn and continuous tracking restart
at zero after reboot; re-zero as needed. A missing I2C sensor is reported as an
error rather than displayed as a valid zero position. Rotation beyond half a
turn between sensor samples cannot be unwrapped reliably.

Device capabilities and app/runtime limits are validated before upload.
“Any size” does not mean unlimited memory: descriptor v1 limits either dimension
to 8192 pixels and the total to 16,777,216 pixels. These are description limits,
not a guarantee that an ESP32 can allocate or render such a framebuffer.

The existing M5Paper media format and e-paper-specific screensaver/refresh
features are not generic display protocols. Clients must disable unsupported
media and update paths rather than send a 540 x 960 M5Paper package to another
screen. Supporting a new panel's images/animation requires an encoder and
firmware decoder for its advertised format.

## Board layout packages

The [board catalog schema](../protocol/board-catalog-v1.schema.json) defines a
versioned index and data-only board package. The package contains a name, exact
board identity/revisions, and geometry. The index pins its SHA-256 digest.
Automatic refresh reads this repository's `main` branch; new local catalog
entries become downloadable after they are published there.

Coordinates use an arbitrary consistent **physical board coordinate space**,
separate from display pixels. Board width/height define its bounds. The screen
rectangle and each stable input ID have positions within those bounds. Geometry
is validated before use; a package cannot invent input IDs.

Layouts can include optional `artworkPNG`: a base64-encoded, single-frame PNG,
up to 2048 pixels per side and 60,000 encoded characters. It is drawn over the
full layout bounds on iPhone/iPad, Mac, and Windows, with transparent selectable
input regions above it. Keep its aspect ratio equal to the layout's width/height
and position each input rectangle over the corresponding physical control.
Artwork travels inside the digest-verified JSON package and is bundled/cached
with it; no external image host or additional download is required. Keep the
whole package below 64 KiB for all clients. The SuperMini MT6701 definition
includes the knob enclosure artwork with its dial above the left/right buttons.
Boards without artwork retain the generic control preview.

When no catalog entry exists, retain the device's basic geometry. Firmware can
generate simple geometry from its input list; no detailed artwork is required.
The setup UI also accepts a manual layout override. Overrides are stored
separately from catalog data and must refer only to device-reported inputs.

To contribute a board:

1. Implement and validate its descriptor/protocol or provide an explicit adapter.
2. Add a JSON package under [boards](../boards) using a new stable board ID.
3. Add its exact revisions, positive package version, filename, and SHA-256 to
   the index. Do not use fuzzy aliases or wildcard hardware revisions.
4. Refresh bundled Swift resources with `sh scripts/sync-board-resources.sh`.
5. Run `python3 protocol/validate.py`, the shared Swift tests, and the affected
   client/firmware tests. Update fixtures when changing a contract.

Do not include pairing credentials, Wi-Fi passwords, executable drivers,
scripts, or firmware binaries in layout packages. Automatic layout downloads
are not automatic firmware installation.

## Firmware and unmodified third-party devices

A JSON layout cannot supply an electrical pin map, display driver, ADC
calibration, transport protocol, or authentication mechanism. Custom firmware
must implement these with a compiled board backend and advertise only features
that work.

The M5Paper backend remains the existing hardware implementation. The screenless
ESP32 and host display/input backends are **reference implementations**, not
claims that an unspecified commercial product has been physically validated.
Review pin assignments and electrical requirements before connecting inputs.

Build targets and host tests:

```sh
pio run -d firmware -e m5paper-v1
pio run -d firmware -e esp32-screenless-reference
bash firmware/tests/run_custom_board_tests.sh
```

Normal reference firmware does not format a failed LittleFS mount: it reports
not-ready and rejects profile installation with `storage_unavailable`, preserving
existing flash. For a new board that needs an initial filesystem, follow
[reference provisioning](../firmware/README.md):

```sh
pio run -d firmware -e esp32-screenless-reference-provision -t upload
```

Observe the explicit format warning on serial, then flash the normal
`esp32-screenless-reference` target **without erasing flash**, before enrolling
credentials. Do not leave the opt-in formatting variant installed on a configured
device.

The screenless reference defaults to an active-low pull-up button on GPIO25,
encoder A/B on GPIO26/GPIO27, and a 0–4095 ADC slider on GPIO34. Its encoder has
no push switch. Compile-time `PAPERGIF_BUTTON_PIN`, `PAPERGIF_ENCODER_A_PIN`,
`PAPERGIF_ENCODER_B_PIN`, and `PAPERGIF_SLIDER_PIN` define the pin map; confirm
these are suitable for your exact board and voltage levels.

For reference network setup, join its `papergif-XXXX` setup AP (default password
`paperdisplay`) and use the serial-reported address, normally `192.168.4.1`.
Install a profile containing your pairing token plus optional `wifiSSID` and
`wifiPassword`. The AP remains available while station Wi-Fi connects. This
reference does not implement the M5Paper's legacy Wi-Fi-start command or
`/wifi` provisioning endpoint. Use it on a trusted setup network.

Firmware uploads are board-specific. New M5Paper images include the
`PGIFBOARD:m5stack.m5paper@1.0;` compatibility marker; the updater refuses a
missing/wrong marker before selecting a boot partition. Previously published
unmarked images cannot be installed through this new firmware's OTA path.
The marker is a compatibility check, not a cryptographic firmware signature.
The screenless reference advertises no OTA support.

An unmodified third-party controller is supported only if a built-in adapter
understands its existing protocol and the operations it exposes. The native and
legacy adapter boundary is available for such integrations. There is no
universal “configure any USB/Bluetooth/Wi-Fi board” adapter, and unsupported
protocols must remain visibly unsupported with writes disabled.

## Developer verification

```sh
python3 protocol/validate.py
swift test --package-path device-kit
swift test --package-path mac-companion \
  --filter 'CustomDeviceProfileTests|DeviceDiscoveryTests|RemoteProfileModelTests'
```

The shared Swift package tests validate descriptor geometry, input identity,
catalog matching/digests, offline behavior, adjustment/clamping, and persistence
isolation. Desktop/iOS tests validate negotiated profile shapes and compatibility.
Host firmware tests exercise reference input/geometry behavior without a board.
Actual display, touch, ADC, encoder wiring, sleep/wake, and connection-loss
behavior still require representative physical hardware testing.
