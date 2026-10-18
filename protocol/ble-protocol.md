# paperGIF BLE Protocol v1

This document records the currently deployed protocol. Revision-aware profile
synchronization will extend it without changing these messages.

## GATT Service

| Purpose | UUID |
| --- | --- |
| Service | `7A230001-7D2A-4C7B-9C42-504749460001` |
| Control write/notify | `7A230002-7D2A-4C7B-9C42-504749460001` |
| Data write | `7A230003-7D2A-4C7B-9C42-504749460001` |
| Device descriptor read/write | `7A230004-7D2A-4C7B-9C42-504749460001` |

## Device Descriptor Extension

New firmware exposes the descriptor characteristic in addition to the existing
service/control/data characteristics. Its absence on known legacy M5Paper
firmware leaves the existing v6 path unchanged; a malformed descriptor is not
permission to fall back to legacy mode.

Write an unsigned four-byte little-endian byte offset **with response**, then
read the same characteristic after write completion. The response is up to
512 raw JSON bytes with no header, opcode, checksum, NUL, or length prefix.
Append bytes and advance the offset by 512 while slices are full. After a short
nonempty slice, write the **total assembled byte count** and read again to obtain
an empty EOF response. Exact multiples also require a final empty read. Complete
the operation only after that empty read, so the reader lease is released.

For example, offset 512 is written as `00 02 00 00`. Decode UTF-8 only after
concatenating all slices, because a slice may divide a multibyte character.
Reject payloads above 64 KiB, invalid JSON, and unsupported descriptor versions.
Use a bounded request timeout and invalidate partial results on disconnect.
Offset-zero writes claim a single reader lease; competing, malformed, and
unclaimed reads/writes cause disconnection rather than changing another reader's
slice. Short nonempty slices retain ownership for ATT Read Blob continuations.
EOF/disconnect releases the lease. A 30-second idle lease disconnects the owner
before another reader can take over. Serialize descriptor requests; they are
independent of profile-upload ownership. Physical concurrent-radio behavior
still requires hardware validation.

The complete descriptor is also available as `GET /device` over HTTP. See the
[device contract](device-protocol.md) for identity, capabilities, and catalog
resolution.

Multibyte integer fields are unsigned little-endian. CRC fields use CRC-32 over
the complete payload. Upload data is sent to the data characteristic in chunks;
firmware acknowledges each 16 KiB window.

## Upload Messages

| Opcode | Direction | Meaning |
| ---: | --- | --- |
| `0x10` | Client to device | Begin media upload |
| `0x11` | Device to client | Media upload ready |
| `0x12` | Client to device | Finish media upload |
| `0x13` | Device to client | Media installed |
| `0x14` | Device to client | All media data received |
| `0x15` | Device to client | Media upload progress |
| `0x40` | Client to device | Begin remote-profile upload |
| `0x41` | Device to client | Remote-profile upload ready |
| `0x42` | Client to device | Finish remote-profile upload |
| `0x43` | Device to client | Remote profile installed |
| `0x44` | Device to client | All remote-profile data received |
| `0x45` | Device to client | Remote-profile upload progress |
| `0x7F` | Device to client | Request or transfer failed |

The begin remote-profile packet is exactly nine bytes:

```text
offset  size  value
0       1     0x40
1       4     payload byte count
5       4     payload CRC-32
```

Progress packets contain the opcode followed by the four-byte received byte
count. The client sends `0x42` after all bytes are written. Firmware may defer
installation until every expected byte is present.

## Library Messages

| Opcode | Direction | Meaning |
| ---: | --- | --- |
| `0x20` | Client to device | List library |
| `0x21` | Device to client | Library count |
| `0x22` | Client to device | Read item at one-byte index |
| `0x23` | Client to device | Delete item at one-byte index |
| `0x24` | Device to client | Item deletion result |
| `0x25` | Client to device | Select item at one-byte index |

## Wi-Fi Messages

| Opcode | Direction | Meaning |
| ---: | --- | --- |
| `0x30` | Client to device | Start device access point |
| `0x31` | Device to client | Access-point information |
| `0x32` | Device to client | Wi-Fi operation failed |
| `0x33` | Client to device | Scan Wi-Fi networks |
| `0x34` | Device to client | Wi-Fi network count |
| `0x35` | Client to device | Read network at one-byte index |
| `0x36` | Device to client | Home Wi-Fi status |
| `0x37` | Client to device | Request home Wi-Fi status |
| `0x38` | Client to device | Prepare home-Wi-Fi upload |
| `0x39` | Client to device | Native boards: join network |
| `0x3A` | Device to client | Native boards: station status |

Native (non-M5Paper) boards scan with `0x33` and reply `[0x34, count]`
once the asynchronous scan finishes (strongest first, up to 20, hidden networks
omitted). `[0x35, index]` returns `[0x35, index, rssi int8, secure 0|1, ssid…]`;
an invalid index returns `0x7F`.

`[0x39, ssidLength, ssid…, password…]` stores the network on the device and
joins it. SSIDs are 1–32 bytes; the password is empty (open network) or 8–63
bytes. A device with a profile accepts this only from a connection registered
as a relay with one of the profile's tokens (`0x70`).

`[0x3A, state, reasonLo, reasonHi, ip0…ip3, ssid…]` reports station state:
`0` not configured, `1` connecting, `2` connected (IP valid), `3` failed. It is
pushed to every subscriber on change and in reply to `0x37`/`0x39`. Reasons are
ESP-IDF disconnect codes (`15`/`202`/`204` wrong password, `201` network not
found, `203` association refused) or request errors (`0xFF01` unauthorized,
`0xFF02` invalid request, `0xFF03` storage failure). Rejected join requests are
reported only to the sender and do not change the tracked state. Networks
chosen this way take precedence over a profile's `wifiSSID` until a profile
naming a network is installed.

## iPhone Media Commands

An `iPhoneMedia` remote action is sent from the device to the subscribed iOS
client as `[0x60, command, value]`. Commands are `0x01` play/pause, `0x02`
previous, `0x03` next, `0x04` volume up, `0x05` volume down, `0x06` mute,
`0x07` seek, and `0x08` set volume. Seek and volume use `value` from 0 to 255.

The iOS client sends its current playback state to the device on the control
characteristic. The packet is at most 64 bytes:

```text
offset  size  value
0       1     0x61
1       1     flags: bit 0 available, bit 1 playing
2       1     volume from 0 to 255
3       4     elapsed milliseconds
7       4     duration milliseconds
11      1     UTF-8 title byte count (0 to 52)
12      n     title, optionally followed by " - Artist"
```

The client sends state after connection and playback changes, and periodically
while progress changes. Firmware advances the timeline locally between packets.

## Live Dial Stream

When a dial's low latency mode is enabled, native boards notify subscribed
clients on the control characteristic at the configured rate (15–500/s,
default 75), sending only changes plus one repeat after motion stops:

```text
offset  size  value
0       1     0x62
1       2     shaft angle, unsigned little-endian centidegrees (0–35999)
3       4     tracked position, signed little-endian centidegrees
```

Full control snapshots continue at their normal rate; clients prefer the
stream for live displays while it is arriving.

Computers on the same Wi-Fi receive streamed dial actions as UDP datagrams on
their companion action port:

```json
{"type":"paperGIF.dialStream","version":1,"boot":123,"seq":42,"token":"…","action":{…}}
```

`boot` is random per device boot and `seq` increments per datagram; receivers
drop datagrams older than the newest seen for that sender and boot, and verify
`token` like an HTTP action. `action` is the same JSON as an HTTP remote
action. Datagrams are at most 2048 bytes.

## State-Machine Requirements

1. Only one media or profile transfer may own the data characteristic.
2. A begin request is rejected when another incompatible upload is active.
3. The client waits for the matching ready notification before writing data.
4. Completion is reported only after byte count, CRC, JSON parsing, and
   transactional installation succeed.
5. Timeouts or disconnects discard the temporary upload; the active profile or
   media file remains intact.
