# paperGIF HTTP and Discovery Contract

## Roles

There are two HTTP servers with different responsibilities:

- A desktop companion receives actions and resolves desktop text sources.
- M5Paper receives profiles, media, Wi-Fi settings, and resolved text updates.

Unless noted otherwise, requests use JSON and an
`Authorization: Bearer <token>` header.

## Discovery

| Role | DNS-SD type | Default port |
| --- | --- | ---: |
| Desktop companion | `_papergif._tcp.local.` | 43821 |
| M5Paper device | `_papergif-device._tcp.local.` | 80 |
| WLED device | `_wled._tcp.local.` | Device-defined |
| Generic HTTP device | `_http._tcp.local.` | Device-defined |
| Shelly device | `_shelly._tcp.local.` | Device-defined |

Current Mac companion TXT fields are `host` and `port`. Clients must normalize
DNS names case-insensitively and must allow manual host entry when multicast DNS
is unavailable.

## Desktop Companion API

`POST /pair` is unauthenticated. All other endpoints require the companion's
bearer token.

### `POST /pair`

Request:

```json
{"deviceName":"Living Room M5Paper"}
```

The desktop must request local user approval. Success is HTTP 200 with
`{"ok":true,"token":"..."}`. A declined request is HTTP 403.

### `GET /status`

Returns HTTP 200 and `{"ok":true}`.

### `GET /applications`

Returns the platform's launchable applications. Existing clients consume each
application's display name, launch target, and optional monochrome icon bitmap.

### `GET /nethome-units`

Returns an array of `{ "id": "stable appliance id", "name": "display name" }`.

### `POST /action`

Request fields:

```json
{
  "type": "macMedia",
  "host": "",
  "text": "playPause",
  "value": 0,
  "valueTenths": 0,
  "modifiers": []
}
```

`host` and `valueTenths` may be omitted. Success is HTTP 200 with
`{"ok":true,"changed":true}`. `changed` is false for a successful idempotent
operation that did not alter state. Invalid or failed actions return HTTP 400.

The `mac*` action names are retained for compatibility and mean desktop-hosted
actions. Capability metadata will determine which actions each host presents.

On Windows, `macMedia` Play/Pause, Previous and Next use the selected Windows
GSMTC media session directly, using the same session-selection policy as seek
and playback-state reads. They never synthesize global media keys: keyboard
sharing utilities can forward those keys to another computer. If no media
session exists or the session rejects the command, the action fails instead of
falling back to keyboard input. Volume/mute continue to use the Windows audio
endpoint; explicit `macKey` actions remain keyboard input.

`openBuilds` is a desktop-hosted integration with OpenBuilds CONTROL. `host`
contains a loopback or private-LAN address with an optional port. Incremental
jog commands are `jogXNegative`, `jogXPositive`, `jogYNegative`,
`jogYPositive`, `jogZNegative`, `jogZPositive`, and the four corresponding
`jogX...Y...` diagonal names. Their distance is `valueTenths / 10` mm when
`valueTenths` is present, otherwise `value` mm. An optional `feed=<100-10000>`
modifier selects mm/min.

Unit-aware controller pages add `units=mm|in` and `dist=<thousandths>`
modifiers. `dist` supersedes `valueTenths`; companions convert inch distance
and feed values to the millimeter-based OpenBuilds socket contract. Actions
without these modifiers retain the legacy millimeter behavior.

`localHTTP` is executed directly by M5Paper and does not require a desktop
companion. `host` is a private IPv4 address or `.local` hostname with an
optional port, `text` is an absolute path, `httpMethod` is `GET` or `POST`, and
`httpBody` is an optional JSON body of at most 191 bytes. M5Paper rejects HTTPS,
public internet hosts, credentials, fragments, and malformed paths.

Continuous XY commands use the same direction suffix prefixed by
`continuousJog`, put feed in `value`, and must be paired with `cancelJog` on
release or pointer exit. Other commands are `pause`, `resume`, `stop`, `abort`,
`unlock`, and `home`. Companions probe CONTROL's `/api/version` endpoint before
emitting an allowlisted Socket.IO event; arbitrary G-code is not accepted.

The `openBuildsPosition` text source uses `host|axis|units` in `sourceText`,
where axis is `x`, `y`, or `z`, and units is `mm` or `in`. The units component
is optional and defaults to `mm` for existing profiles. The companion
subscribes to CONTROL status and returns the converted current work coordinate
without issuing machine movement.

### `POST /text-source`

Accepts up to 16 items:

```json
{
  "items": [
    {
      "id": "control UUID",
      "source": "nowPlaying",
      "sourceText": "",
      "placeholder": "Nothing playing"
    }
  ]
}
```

Response:

```json
{
  "items": [
    {
      "id": "control UUID",
      "text": "Artist - Track",
      "available": true,
      "value": 128
    }
  ]
}
```

`value` is optional. Media responses may also include `elapsedMilliseconds`,
`durationMilliseconds`, and `playing`.

On Windows, authenticated reads of `nowPlaying`, `playbackState`, and
`outputVolume` subscribe those control IDs to live updates. The callback is
`http://<request-peer>:80/text-source/update`, never a caller-supplied URL;
only private/link-local LAN peers are eligible. IPv4-mapped IPv6 addresses are
normalized. Partial reads merge with existing subscriptions rather than replacing
other pages or controls. Registration is in-memory: reopening the remote page
reestablishes subscriptions after a companion restart.

Windows samples one shared local media/volume snapshot per second while subscribed.
Changed track, playback, duration, availability, or volume data is pushed using
the companion's own bearer token. Track changes also resync playback-only controls.
Steady elapsed progress does not generate per-second network traffic; available
timelines get a 30-second resync. Failed deliveries are retried with the newest
snapshot using bounded backoff (2–60 seconds), reset by a fresh read. Subscriptions
are capped at eight peers and 128 controls per peer, with batches of at most 16.
Scripts and other text sources are not background subscriptions.

## M5Paper API

M5Paper accepts requests from its access-point network or requests authenticated
with a configured companion token, depending on endpoint.

### `GET /status`

Unauthenticated readiness probe. Returns `device`, `ready`, `uploading`, and
`ssid` fields.

### `GET /remote`

Requires device authorization. Returns the stored profile with live slider,
toggle, and thermostat values merged into matching controls.

### `POST /remote`

Requires device authorization. The body is a remote profile no larger than
256 KiB. Firmware parses a temporary file, transactionally replaces the active
profile, and returns HTTP 201 with `{"ok":true}`. Invalid profiles return 400.

### `POST /text-source/update`

Requires device authorization. A desktop companion uses this endpoint to push
resolved text/value changes back to M5Paper. Each item is applied only when its
bearer token matches the control's currently selected computer. Items from an
old subscription after retargeting are ignored, even if that companion remains
paired. General device/session authorization alone does not identify a media
state source.

Push bodies must include `Content-Length`; Arduino WebServer does not decode
chunked request bodies. Windows buffers UTF-8 JSON before sending and disables
HTTP redirects so callbacks cannot forward pairing credentials elsewhere.

### Computer selection

- A nonempty action `computerID` selects that paired computer (UUID comparison
  ignores letter case). A missing match is unavailable, never another computer.
- An omitted/null/empty action `computerID` selects the first paired computer.
  Legacy `macHost`/`macPort`/`macToken` are used only when no paired list exists.
- Media buttons and sliders query playback/volume state from their action target;
  leftover text-box computer settings cannot override it. Actual text boxes can
  use a separate text-source `computerID` and tap-action target.
- Choosing a specific computer in the editor pins the control to that UUID;
  choosing Default Computer intentionally follows the first list entry.

### Access-point-only endpoints

- `GET /library`
- `POST /library/active?index=<index>`
- `POST /wifi/off`
- `POST /upload`

`GET /wifi/networks` accepts the normal device authorization rules.

## Current Security Boundary

- Transport is HTTP on the local network; TLS is not currently part of the
  protocol.
- Tokens are bearer credentials and must never appear in logs or fixtures.
- Companion pairing requires local user approval.
- Implementations should bind only where needed, limit request sizes, compare
  tokens without early exit, and restrict firewall rules to private networks.
