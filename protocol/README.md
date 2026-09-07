# paperGIF Protocol

This directory is the platform-neutral contract shared by the M5Paper firmware,
the iPhone app, the Mac companion, and the planned Windows companion.

## Baseline

- `remote-profile-v6.schema.json` describes the currently deployed profile.
- `fixtures/remote-profile-v6-all-actions.json` exercises every current action
  type and the optional profile fields used by the apps and firmware.
- `companion-api.md` separates the desktop companion API from the M5Paper API.
- `ble-protocol.md` records the currently deployed BLE protocol before adding
  revision-aware synchronization.

The fixture contains only fake hosts, tokens, and credentials. Never place real
credentials in protocol fixtures.

## Compatibility Rules

1. Existing JSON property names and action values are wire protocol and cannot
   be renamed without a migration period.
2. `macMedia`, `macKey`, `macOpen`, `macShortcut`, and `macScript` are legacy
   protocol names. New platforms may present platform-specific labels while
   continuing to use these values on the wire.
3. `openBuilds` actions are executed by the selected desktop companion and may
   contain only the command names documented in `companion-api.md`.
4. Readers must tolerate optional fields they do not use. Writers must respect
   the firmware limits encoded in the schema.
5. Stored profiles do not contain `deviceClock`. Clients may add it only to the
   payload sent to M5Paper.
6. A fixture change is incomplete until Mac, iPhone, Windows, and firmware
   contract tests agree on it.

## Validation

```sh
python3 -m pip install -r protocol/requirements.txt
python3 protocol/validate.py
```
