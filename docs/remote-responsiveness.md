# Remote responsiveness

## Implemented first pass

- M5Paper button press/release and action-status rendering is deferred until the
  e-paper panel is idle. The latest visual states are batched; the input handler
  does not wait for these refreshes. Slider commands are queued before drawing.
- Side-button page settling is 250 ms instead of 700 ms. Full page clean-up
  refreshes and the configured button quality-refresh interval are preserved.
- Firmware has three independent, serial network lanes: interactive controls,
  NetHome/climate actions, and text/diagnostic traffic. Each lane has eight
  pending slots in PSRAM and one active request. Workers run at idle priority on
  core 0 so blocking socket calls do not starve the watchdog's idle task.
- Only consecutive pending updates to the same slider, URL and profile revision
  coalesce. Different sliders and intervening buttons are not overwritten.
- Queue occupancy and active requests are tracked under one mutex. A newer
  request finishing on another lane cannot incorrectly allow deep sleep.
- HTTP headers are written together and TCP_NODELAY is enabled for control
  messages. Connections still close after each request; keep-alive and endpoint
  caching are intentionally outside this first pass.
- The Mac server has bounded serial lanes for interactive actions, climate,
  text sources and catalog/log work. Pairing approval no longer blocks its
  network queue. Ordering is retained within each lane, not across lanes.
- Connections have a 10-second receive limit. Once validated, operation budgets
  are 4 seconds for interactive work, 33 for climate, 14 for text, and 30 for
  catalog work. Pairing permits 60 seconds for user approval. Queued work checks
  a monotonic deadline and cancellation immediately before beginning.
- Mac media state is queried once per text batch. Notification-driven media
  reads run outside the main thread, with at most one active and one coalesced
  pending refresh. UI/subscription publication remains on the main thread.

## Limits and ordering

This does not turn an already-started action into a cancellable transaction.
An Apple Event, cloud command or subprocess already running when the client
disconnects can still take effect. In particular, first-time NetHome dependency
installation or waiting for an editor-owned NetHome operation can exceed the
response budget. Do not automatically retry non-idempotent actions on timeout.

OpenBuilds motion and cancel commands stay on the same interactive FIFO; a
cancel never overtakes an earlier jog that could then restart motion. This is
not a hard-real-time emergency-stop channel. Existing machine-state checks are
unchanged. Climate activity and polling no longer hold this FIFO.

The first scheduling pass did not change the Windows companion or iOS app.
Firmware lane separation benefits either desktop companion, but the Mac
scheduling changes apply only to the Mac host. The subsequent iOS editor fix
is described below.

## Validation and timing

`firmware/tests/remote_network_queue_test.cpp` tests lane selection, coalescing,
ordering barriers, overflow, wraparound, revision/target isolation and active
work across lanes. Run with the other standalone C++ firmware tests.

`CompanionRequestSchedulerTests` covers receive/operation deadlines, expired
and cancelled request admission, independent lanes, FIFO and bounded backlog.
Run with the Mac companion's Swift test suite.

Firmware serial output reports `lane`, `queue` time and `request` time for each
request, without tokens or payloads. Compare these with physical tap timing;
they do not include touch detection or e-paper refresh time. Suggested device
checks: rapid play/pause taps, volume release, two different sliders, navigation,
controls during a slow text/cloud request, reconnect, and sleep after all lanes
drain. No measured end-to-end speedup is claimed without these device checks.

Validation on 2026-09-13: all five firmware host test programs and all 48 Mac
tests passed. Firmware was flashed and the signed Mac app rebuilt/reopened.
Serial capture confirmed all three workers, Wi-Fi/BLE connections and successful
media-state retrieval. Initial sustained checks exposed a separate profile-download
memory problem, diagnosed and fixed below.

## Computer connection failure: profile JSON memory

The iPhone requests `GET /remote` after connecting over BLE. With the saved
27.8 KB profile and both radios active, the default ArduinoJson allocator reduced
free internal RAM from about 20 KB to 4.6 KB during parsing, then 3.2 KB during
serialization. Subsequent inbound HTTP and outbound TCP/mDNS requests timed out
even though Wi-Fi remained associated at approximately -50 dBm. Both companion
servers and their saved pairing tokens were independently verified healthy.

Disabling phone Bluetooth initially hid the problem because it also prevented
the automatic profile download. A controlled test retained the BLE connection
but skipped app commands; networking stayed healthy until a desktop initiated
`GET /remote`, reproducing the failure. All command handling was restored.

`PsramJsonAllocator` now keeps profile JSON nodes and strings exclusively in
PSRAM, for both profile parsing/install and profile downloads. There is no
fallback to scarce internal RAM. Serialization reserves its output once and
checks allocation/serialization failure rather than returning a truncated
profile as HTTP 200. Small action and text JSON documents are unchanged.

Original Wi-Fi modem sleep and BLE connection parameters are preserved. Temporary
tests of zero BLE peripheral latency, Wi-Fi radio preference, and disabled BLE
controller sleep did not fix the issue and were removed. Disabling Wi-Fi modem
sleep caused a startup abort in `coex_core_enable` with this prebuilt SDK and
was reverted. No power-saving tradeoff is part of the final fix.

After the PSRAM fix, a 120-second physical-device capture with BLE connected
passed 27/27 HTTP checks: 18 status requests and 9 authenticated profile downloads,
all valid JSON. Downloads took 0.59–0.81 seconds and retained approximately
21–24 KB internal RAM after parsing/serialization. Additional automatic phone
profile pulls, a BLE disconnect/reconnect, background media queries and physical
Mac media actions succeeded. The user also confirmed controls on both Mac and
Windows computer pages work with iPhone Bluetooth on.

All six firmware host programs pass, including the new
`firmware/tests/psram_json_allocator_test.cpp`: PSRAM capability routing,
allocation/reallocation failure, repeated >64 KB profile parse/serialize cycles,
live-value preservation and cleanup. Build that test with the usual C++11 warning
flags plus `-Ifirmware/tests/stubs` and
`-Ifirmware/.pio/libdeps/m5paper-v1/ArduinoJson/src`. The stub heap header is only
for host tests; firmware builds use the ESP32 SDK allocator.

Firmware was rebuilt and flashed. Serial logs retain profile allocation and
BLE-parameter diagnostics without credentials or profile contents. These are
bounded-duration hardware checks, not a long-term reliability or battery claim.

## Playback time and seek controls

The firmware status line now shows elapsed/total time on pages with media
Play/Pause buttons as well as seek sliders, including when playback is paused.
It selects the desktop or iPhone timeline from the control's action type,
advances at one-second resolution independently of the 8-bit slider value,
and defers status redraws until the panel is idle. Stale/paused positions do
not advance; dragging previews the requested position without live updates
overwriting the drag value. Desktop timelines are still shared across computers;
this change does not introduce per-computer timeline isolation.

[media_timeline_test.cpp](../firmware/tests/media_timeline_test.cpp) covers
transport-only pages, source selection, paused/stale timelines, dragging,
long-track second resolution, duration clamping and timer rollover. All seven
firmware host programs passed, the firmware was rebuilt/flashed, and a subsequent
75-second hardware check passed 14/14 status/profile requests with BLE connected.
The user confirmed elapsed time works. The Main Music control was a text box,
not a seek slider; converting that saved control to a Mac-targeted seek slider
also restored seeking, confirmed on the device.

## iPhone editor: media source selection

The editor previously reset every media action to Play/Pause on an action-type
change, then converted sliders to buttons. This hid the slider-only Outline
setting. Selecting the Seek command did not restore the slider kind either.

The editor now uses tested model transitions to preserve seek/volume commands
and outline/layout/text styling when switching Mac/iPhone media providers.
A new slider defaults to Volume on media selection (Seek for an existing
now-playing slider); selecting Seek or Volume makes a non-text control a slider.
Transport commands use buttons, while text boxes retain their media tap actions
without changing kind. New seek controls initialize now-playing text using the
selected computer.

Five regression tests were added to
[paperGIFTests.swift](../paperGIFTests/paperGIFTests.swift). Independent host
checks against the actual iOS profile model passed all five behavior groups,
compiled with warnings as errors. After a separate in-progress music-player build
error was resolved, the final iOS build succeeded and all five regression tests
passed on the connected physical iPhone (verified in the result bundle, with no
skips). The updated app was installed and launched successfully; no simulator
was used. Manual confirmation that Outline stays visible in the editor is pending.

When selecting individual Swift Testing tests with Xcode, include the trailing
`()` in the quoted `-only-testing` function identifier. Omitting it completed
successfully with zero tests; always verify the executed count in the result
bundle, not just the command exit code.

## Play/Pause computer targeting

Investigation found two independent ways a command and its displayed state could
disagree. Untargeted actions used the legacy `macHost` endpoint, while state reads
used the first paired computer. Mac/Windows editor startup can rewrite legacy
fields to the local companion without moving that computer to the first position.
Also, pushed playback state was accepted from any authorized companion based only
on control ID; an old subscription could overwrite a retargeted control's state.

Firmware now shares [remote_computer.h](../firmware/include/remote_computer.h)
resolution for actions and state reads: explicit UUID (case-insensitive), otherwise
first paired computer, otherwise legacy endpoint only if no computers exist.
Explicit missing targets fail closed. Media buttons/sliders use their action's
computer for state even if old text settings mention another computer. Genuine
text boxes retain independent text/tap-action targets. Pushes must match the
selected computer's token, and polled responses must match its endpoint and token.
Action diagnostics include control ID and selected computer/endpoint, never tokens.

Validation: all eight firmware host programs passed, including target/default
selection, UUID casing, missing IDs, retargeting and response isolation. Firmware
built and flashed successfully. Device profile readback showed Main media controls
explicitly target the Mac; Windows Test and Media controls explicitly target
SESKTOP. No saved profile assignments were changed. A hardware probe authenticated
as the Mac tried to update a Windows volume control; it was ignored (displayed
value remained 171 rather than 255), exercising the same source gate as Play/Pause.
No playback command was sent during that probe. The user's original intermittent
wrong-command event was not explained by this probe; the follow-up below traced
the actual command path.
The previously noted shared desktop elapsed-time timeline is a separate remaining
limitation, not a command-routing mechanism.

## Windows media keys forwarded by input sharing

After the user reported the wrong-machine behavior still occurred, a 75-second
serial capture recorded two real taps on Media page control
`F70EA00D-9AEB-4613-BDB4-522C815E7966`. Both resolved to the SESKTOP UUID and
`192.168.50.44:43821`; both HTTP actions succeeded in 50–62 ms. The firmware was
not sending these commands to the Mac.

The Windows companion implemented Play/Pause/Previous/Next using `keybd_event`
global media-key injection. ShareMouse was running on SESKTOP, making keyboard
forwarding a concrete suspect after the request reached Windows. Seek already
used a direct Windows media session, explaining why its behavior could differ.
No ShareMouse settings/processes were changed to perform the fix.

[WindowsMediaTransport.cs](../windows-companion/src/PaperGIF.Windows.Host/WindowsMediaTransport.cs)
now calls GSMTC `TryTogglePlayPauseAsync`, `TrySkipPreviousAsync` and
`TrySkipNextAsync` on a selected session. Selection is shared with seek and state
reads. There is no keyboard fallback for an absent/unsupported media session.
Diagnostics record the selected app ID and operation result without track titles
or credentials. App-specific cloud remote-control behavior (such as a player's
own cross-device feature) remains outside this machine/session boundary.

All 54 Windows tests passed on SESKTOP (7 Core, 47 Host), including 12 new
transport cases. The companion was published, installed and restarted in the
interactive desktop session. A real authenticated Play/Pause request changed
Windows from paused to playing while the Mac remained paused, with ShareMouse
still running. The installed companion logged a successful direct session call.
Subsequent Play/Pause requests also logged successful session calls; further user
taps overlapped the diagnostic, so no final playback-state restoration is claimed.
No additional firmware, iOS, Mac companion or saved-profile changes were required.

## Windows song metadata not updating

The next report was stale song data, separate from command routing. A live
`/text-source` query returned valid Windows track metadata and a timeline, and
the Media page's seek control explicitly targeted SESKTOP. The Windows endpoint
only resolved incoming polls: it had no subscriptions or background pushes.
Firmware sets a seek/playback control's `nextRefreshAt` to zero after a valid
timeline, relying on companion updates. Plain now-playing text boxes instead
poll every 60 seconds. Consequently, Windows could return the right song when
queried while the remote retained old metadata indefinitely between interactions.

[WindowsMediaUpdateService.cs](../windows-companion/src/PaperGIF.Windows.Host/WindowsMediaUpdateService.cs)
now reads one shared GSMTC/audio snapshot per second while subscribed.
[WindowsMediaUpdatePublisher.cs](../windows-companion/src/PaperGIF.Windows.Host/WindowsMediaUpdatePublisher.cs)
registers authenticated LAN request peers and sends changed title, playback,
duration, availability and volume data to the existing device push endpoint.
It merges partial polls, preserves other pages, resyncs transport-only controls
on track changes, deduplicates smooth elapsed progress, and sends a 30-second
timeline heartbeat. Failed deliveries retry the newest snapshot with bounded
backoff; successful delivery is tracked separately per device/control. Registries
and batch sizes are bounded. It does not run scripts in the background, accept
callback URLs, or log song titles/tokens. Subscriptions are in-memory, so reopen
the remote page after restarting the companion.

The first hardware check caught HTTP 400 from Arduino WebServer because .NET
`JsonContent` streamed a chunked body. Buffered UTF-8 JSON with `Content-Length`
fixes the framing; a regression checks the length before reading the body.
HTTP redirects are disabled to avoid forwarding bearer tokens.

All 78 Windows tests passed on SESKTOP (7 Core, 71 Host), including 24 new
publisher/endpoint cases covering track changes without play-state changes,
partial subscriptions, per-device delivery, retries, source changes, authentication,
request framing, heartbeat/deduplication, and device/control/batch limits.
The companion was republished and restarted using the interactive scheduled task.
After the final restart, the real M5Paper (`192.168.50.142`) registered its volume
control and acknowledged the buffered push with HTTP 200 at 18:41:23 UTC, replacing
the earlier HTTP 400 failures. This runtime check validates callback delivery;
track-change mapping is covered by tests, not a claimed physical display check.
No media commands, saved-profile edits, or firmware/iOS/Mac code changes were
needed for this fix. Physical song-change display confirmation remains pending.