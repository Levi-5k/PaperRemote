# paperGIF BLE Protocol v1

This document records the currently deployed protocol. Revision-aware profile
synchronization will extend it without changing these messages.

## GATT Service

| Purpose | UUID |
| --- | --- |
| Service | `7A230001-7D2A-4C7B-9C42-504749460001` |
| Control write/notify | `7A230002-7D2A-4C7B-9C42-504749460001` |
| Data write | `7A230003-7D2A-4C7B-9C42-504749460001` |

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

## State-Machine Requirements

1. Only one media or profile transfer may own the data characteristic.
2. A begin request is rejected when another incompatible upload is active.
3. The client waits for the matching ready notification before writing data.
4. Completion is reported only after byte count, CRC, JSON parsing, and
   transactional installation succeed.
5. Timeouts or disconnects discard the temporary upload; the active profile or
   media file remains intact.
