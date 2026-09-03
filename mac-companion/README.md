# paperGIF Mac Companion

A menu-bar receiver and visual M5Paper remote editor.

```sh
swift run PaperGIFMac
```

Choose **Open Controls Editor…** from the menu-bar icon to create pages, arrange controls against a device-accurate preview, configure Mac and WLED actions, and save the profile locally.

The editor includes the same setup controls as the iPhone app: nearby Wi-Fi scanning, current-network and password setup, screensaver timing, page and control ordering, labels/icons/colors/sizes, every action type, multi-computer discovery and pairing, WLED discovery, named presets, and one-click WLED pages.

Whenever the editor opens, it discovers M5Paper on the home network and loads its active layout and settings with the paired Mac credential. If the device is unreachable or returns an invalid profile, the saved local draft remains unchanged and the editor shows the connection error.

To install a profile directly from the Mac, keep the Mac and M5Paper on the same home network and choose **Send to M5Paper**. If home Wi-Fi is not configured yet:

1. Open Wi-Fi mode on the M5Paper.
2. Join its `paperGIF-…` network using the password `paperdisplay`.
3. Leave the device address as `192.168.4.1` and choose **Send to M5Paper**.

The device validates the complete profile before replacing its active remote. The editor supports up to 8 pages and 16 controls per page, matching the firmware limits.

Open the paperGIF iPhone Remote tab, select the discovered Mac, and request pairing when editing from iPhone. Approve the request on the Mac; the credential is exchanged and saved automatically. Script actions are rejected unless the exact command appears in the companion's allowed-script list.

Keyboard shortcuts require Accessibility access in System Settings. The server advertises `_papergif._tcp` through Bonjour and listens only for authenticated `POST /action` requests.
