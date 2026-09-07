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

`value` is optional.

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
resolved text/value changes back to M5Paper.

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
