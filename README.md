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