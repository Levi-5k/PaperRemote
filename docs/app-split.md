# paperGIF / XPlayer app split

**XPlayer** (capital X and P) is the separate music player. The original paperGIF
app keeps GIF/image conversion, the phone and device media libraries, device
setup, remote-profile editing and synchronization, computer controls, and
HomeKit/Matter features. Music playback and its eight Metal visualizers belong
to XPlayer, not to a replacement paperGIF installation.

## Keep the original data container

- The original app bundle identifier stays **human-programs.paperGIF** in both
  build configurations. Update it in place; do not uninstall it to perform the
  split. XPlayer must use its own bundle identifier and container.
- The legacy library remains under **Application Support/paperGIF-v2/Music** in
  paperGIF's existing sandbox. Removing playback source files does not remove
  library files. No migration runs at startup and no player is instantiated.
- Do not uninstall paperGIF until the Files copy and the XPlayer import are
  verified. Uninstalling an app can delete its local data. Keep a backup of the
  exported library independently of both apps.

## Manual migration through Files

1. On the device that holds the old library, open **paperGIF → Settings → Move
   Music to XPlayer → Export paperGIF Library**.
2. In the system Files picker choose a writable destination, such as iCloud Drive
   or an On My iPhone/iPad folder. Save the folder copy. Prefer a new destination
   if a folder named **Music** already exists; avoid replacing an unrelated
   library. The destination needs room for the complete library.
3. Check that Files contains the exported **Music** folder and its subfolders.
   If importing on another device, wait for cloud upload/download to complete.
4. In **XPlayer**, choose **Import paperGIF Library** and select that exported
   **Music** folder itself, not the parent destination, its inner default Music
   collection, or individual songs. The XPlayer side implements this matching
   folder-import option separately; this change only implements paperGIF export.
5. Verify the expected songs, folders, and playback in XPlayer. Both the original
   library in paperGIF and the Files copy remain available; neither is moved or
   deleted by this export.

If there is no legacy library, or it contains only empty folders, Settings
explains that there is nothing to export. Lookup/read errors are shown without
changing the library. Unlock the device and retry if data protection prevents
reading it. Cancellation is harmless and does not report success. Errors while
choosing/writing the destination are handled by the system Files/provider UI;
`UIDocumentPickerDelegate` has no separate export-error callback. Retry in a
writable location with adequate space. The success notice follows the picker's
completion callback, not confirmation of cross-device cloud synchronization.

## Export / import contract

- Source: the **existing** Application Support/paperGIF-v2/Music directory in
  the original app container. Lookup uses `create: false`, never the old
  directory-creating player/storage helpers.
- Export: `UIDocumentPickerViewController(forExporting: [root], asCopy: true)`
  presented from Settings through `UIViewControllerRepresentable`, only after
  the user taps Export. There is no staging copy, archive, flattening, audio
  conversion, metadata rewrite, automatic migration, or cleanup of source data.
- Payload: one folder tree whose suggested outer name is **Music**. All regular
  files (including hidden files, sidecars and artwork), relative subfolder paths,
  and empty subfolders within a nonempty library are passed intact to Files.
  Providers may rename the outer folder or vary filesystem metadata support;
  filenames/relative paths and file contents are the migration contract, not
  preservation of filesystem timestamps or extended attributes.
- The old default collection produces **Music/Music/song.m4a**. Other examples
  are **Music/Artist/Album/song.m4a** and **Music/Collection/song.m4a**. Do not
  collapse either Music level or flatten same-named files from different folders.
- Preflight traverses metadata off the main actor and requires at least one
  regular file anywhere in the tree. It rejects a non-directory root, symbolic
  links and unsupported filesystem entries rather than following them outside
  the library. It does not decode audio or omit unrecognized file extensions.
- XPlayer's matching import must request a **folder**, acquire security-scoped
  access while reading it, recursively **copy** supported contents into its own
  library while preserving relative subfolders, and leave the exported Files
  tree untouched. Destination collision/duplicate policy is owned by XPlayer;
  it must not silently overwrite different songs or destroy folder structure.
  No shared sandbox, App Group, bundle-ID reuse, or access to paperGIF's private
  Application Support directory is required or assumed.

## Bluetooth ownership and original-app scope

The original [ContentView](../paperGIF/ContentView.swift) no longer creates a
music player, shows a Player tab, forwards music commands into playback, or
publishes player state. HomeKit events and remote-profile synchronization remain.
The notification-subscription callback in
[PaperGIFBluetoothManager](../paperGIF/PaperGIFBluetoothManager.swift) no longer
publishes the fallback empty **0x61** music state, which would overwrite XPlayer's
now-playing state on M5Paper. Inbound **0x61** HomeKit commands, outbound **0x63**
HomeKit status and the **0x62** phone registration are unrelated and retained.

Compatible music protocol types and explicit state-send helpers remain inert:
there is no caller of `syncLocalMediaState` in the original app, so its pending
state stays nil and existing transfer-completion flushes have nothing to send.
Do not reintroduce automatic music-state publication in paperGIF. Firmware and
remote-editor music action definitions are not removed by this split.

The original [Info plist](../paperGIF-Info.plist) drops only the `audio`
background mode; `bluetooth-central` and unrelated permissions remain. The
file-system-synchronized Xcode app and test groups discover the new migration
files automatically; no project or signing changes are needed.

## Exact original-app file changes

Modified:

- `README.md`
- `paperGIF-Info.plist`
- `paperGIF/ContentView.swift`
- `paperGIF/PaperGIFBluetoothManager.swift`
- `paperGIF/PaperGIFSettingsView.swift`

Added:

- `docs/app-split.md`
- `paperGIF/PaperGIFLegacyMusicLibrary.swift`
- `paperGIF/PaperGIFLegacyMusicExportSection.swift`
- `paperGIFTests/PaperGIFLegacyMusicLibraryTests.swift`

Deleted from the original repository only, after the main agent reported
SHA256-verified sibling copies:

- `paperGIF/PaperGIFMusicPlayer.swift`
- `paperGIF/PaperGIFMusicAnalyzer.swift`
- `paperGIF/PaperGIFMusicRenderCapture.swift`
- `paperGIF/PaperGIFMusicVisualizer.swift`
- `paperGIF/PaperGIFMusicVisualizer.metal`
- `paperGIFTests/PaperGIFMusicVisualizerTests.swift`

The removed files were untracked in the original working tree, so their deletion
does not appear as a tracked `D` in `git status`. The XPlayer workspace, original
project settings, existing tests, storage helpers, firmware and companions are
not modified by this extraction. Existing unrelated dirty changes are retained.
All content edits used patches. Two deletion patches reported success without
removing the files; after explicit user approval, only the six paths above were
deleted in the terminal and their absence was verified.

## Validation / outstanding device checks

[PaperGIFLegacyMusicLibraryTests](../paperGIFTests/PaperGIFLegacyMusicLibraryTests.swift)
covers the exact path, absent and empty libraries (including the old empty
default folder), a file at the root path, symbolic links, repeated read-only
lookups, nested/Unicode paths, same-named songs, hidden/sidecar files, and
preservation of source bytes, tree entries and modification dates. Tests use
unique temporary fixtures only, never the installed user library.

This extraction does not build, install, run tests, or use a simulator. The main
agent coordinates builds and physical-device validation. Static checks passed:
Swift frontend parse-only syntax validation of the changed Swift sources/tests,
plist/project syntax validation, whitespace checks, and source assertions for
the exact removal inventory, copy-only export, no remaining player references or
music-state sync callers, retained HomeKit/device/UI entry points, unchanged
bundle ID, and Bluetooth-only background mode. Editor diagnostics reported no
errors. These checks are not a typechecked build, test execution or runtime proof.
Still verify:

- Settings export success/cancellation/errors with local and iCloud Files
  providers on physical iPhone/iPad, including large libraries and low space.
- Source library contents unchanged after export and destination folder tree
  intact; then the matching XPlayer import and playback.
- paperGIF connection/reconnection does not overwrite XPlayer's now-playing
  state; HomeKit, remote editing/sync, and GIF/media upload still work.
- M5Paper firmware supports the intended simultaneous-app/device routing. This
  patch preserves registration behavior and makes no firmware changes.

The retained [music visualizer notes](music-visualizers.md) describe the extracted
implementation; their original-app playback/source locations are historical.