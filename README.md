# PaperRemote

PaperRemote turns an M5Stack M5Paper into a configurable remote. An iPhone or Mac editor builds the control layout, the ESP32 firmware renders and runs it, and a macOS menu-bar companion handles Mac actions and dynamic text sources.

## Components

- `paperGIF/`: SwiftUI iPhone editor and media uploader
- `mac-companion/`: AppKit/SwiftUI menu-bar companion and remote editor
- `firmware/`: PlatformIO firmware for M5Paper v1
- `paperGIFTests/` and `paperGIFUITests/`: iOS tests

## iPhone App

Open `paperGIF.xcodeproj` in Xcode, select the `paperGIF` scheme, and run it on an iPhone. The app uses Bluetooth and local-network access to configure and communicate with the M5Paper.

Command-line build check:

```sh
xcodebuild -project paperGIF.xcodeproj \
  -scheme paperGIF \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build-for-testing
```

## Mac Companion

Build and test the Swift package:

```sh
swift test --package-path mac-companion
```

Package, sign, and open the menu-bar app using an available Apple Development identity:

```sh
./mac-companion/package-app.sh debug
```

The companion uses macOS automation permissions for Music and a private MediaRemote framework for event-driven now-playing updates. Private framework behavior may change between macOS releases.

## M5Paper Firmware

Install PlatformIO, connect an M5Paper v1, then build and upload:

```sh
pio run -d firmware -e m5paper-v1
pio run -d firmware -e m5paper-v1 -t upload --upload-port /dev/cu.usbserial-DEVICE
```

The default temporary setup network password is `paperdisplay`. Home Wi-Fi and pairing credentials are stored on the device or in each app's local application-support directory, not in this repository.

Battery optimizations and the measured roadmap for future improvements are documented in [docs/power-optimization.md](docs/power-optimization.md).

### Geometric Snake screen saver

On the M5Paper, open **Settings → Screen Saver**, turn **Enabled** on, and tap
**Style** to select **Geometric Snake** instead of **Library Media**. Close settings
to return to the remote; the animation starts after the configured **Start After**
delay. No uploaded image or GIF is required.

Dozens of plain black lines move along a procedurally planned, random-looking
route across the entire 540 × 960 display. The original invisible honeycomb grid
is unchanged: the same 22-pixel edges, positions and 60-degree directions, with
no decorative shapes or head markers.

On entry, a seeded cycle-expansion algorithm builds a long irregular closed loop
using only existing grid edges. It replaces an edge with a five-edge hexagonal
detour only when the new vertices are unused, preserving a simple non-crossing
cycle. Snakes then follow that plan instead of choosing random turns as they move.
Equal speed and at least three empty vertices between bodies guarantee continuous
forward movement: no stopping, reversing, crossings or teleporting at the loop seam.

Population scales with route length (bounded to 80 snakes), packing one 12-vertex
snake per 15 route vertices while preserving gaps. This is a density budget,
not a measured hardware maximum. A fixed-size simulation and one monochrome
offscreen canvas keep memory and rendering work bounded. Only changed areas
(mostly line tips) are uploaded, batched into one panel update per frame; full
uploads are reserved for entry and cleaning. The animation runs without a fixed
FPS cap, at the rate the panel and transfer bus can sustain, with eight movement
substeps per hexagon edge. No frames are queued while the panel is busy. A
cleaning refresh every 240 frames limits ghosting. Serial diagnostics report
achieved FPS, render/transfer time and the uploaded screen percentage every
five seconds; sparse transfers do not eliminate the panel's waveform duration.
Touch the screen or press a side button to return to the remote.

Live animation keeps the device awake and uses more battery than static images.
Sleep-between-images and image-interval settings apply only to **Library Media**;
their saved values are preserved when switching styles. The style is saved on the
device's SD card and is independent of iPhone/Mac remote-profile edits.

**Images Below 100%** in the device's Screen Saver menu is an optional battery
policy (off by default). When enabled, only still library images are shown below
100%; at a reported 100%, the selected live background or GIF playback resumes.
Battery state is checked every 10 seconds while awake, including while the screen
saver is running. Charging below 100% still uses images; an unavailable battery
reading also uses images. The chosen style is preserved.

Below 100%, still images use the existing image interval. If no still is available,
the screen saver rotates through a static frame from each library item at that
interval; a library containing one GIF advances it by one frame per interval. With
no media, a static “Add media” message is displayed. The temporary fallback does
not overwrite the saved media selection. Existing sleep-between-images behavior
remains available for single-frame media in Library Media mode.

Host-side geometry and rendering checks (no device required):

```sh
clang++ -std=c++11 -Wall -Wextra -Werror -Ifirmware/include \
  firmware/tests/geometric_snake_test.cpp -o /tmp/papergif-snake-test
/tmp/papergif-snake-test
clang++ -std=c++11 -O2 -Wall -Wextra -Werror -Ifirmware/include \
  firmware/tests/monochrome_damage_test.cpp -o /tmp/papergif-damage-test
/tmp/papergif-damage-test
```