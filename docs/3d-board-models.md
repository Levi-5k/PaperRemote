# 3D board models (design proposal)

Status: **not implemented**. This describes how board packages could add an
optional, animated 3D model of a device whose knobs turn and buttons press in
step with the real hardware. Boards without a model keep the existing 2D
layout and artwork described in [custom-devices.md](custom-devices.md#board-layout-packages).

## Why GLB

- **GLB** (binary glTF 2.0) is a runtime format: one file holding meshes,
  materials, textures, and a named node hierarchy, with per-node transforms.
  Every client platform can render it:
  - iPhone/iPad and Mac: use a **converted USDZ variant** with RealityKit.
    Keep GLB as the source of truth; convert once when building a package,
    not each time a device preview opens.
  - Windows: WinUI 3 has no built-in 3D view; render with a lightweight
    glTF renderer such as SharpGLTF + a Direct3D/Win2D surface, or a WebView2
    hosting three.js/`<model-viewer>`.
- **3MF** stays useful as the *source* for printed enclosures. It supports
  separate objects and component assemblies, but it describes manufacturing,
  not motion, and is not designed for real-time rendering. Authors convert
  3MF (or STEP/STL) to GLB once, for example with Blender, keeping each moving
  part a separate named object.

## Package layout

The model is a separate file referenced and pinned by the board package, so the
JSON package stays under its 64 KiB limit:

```json
{
  "boardID": "supermini-s3-mt6701",
  "layout": { "...": "existing 2D geometry and artworkPNG" },
  "model": {
    "assets": {
      "glb": {
        "file": "supermini-s3-mt6701.glb",
        "sha256": "…",
        "bytes": 412337
      },
      "usdz": {
        "file": "supermini-s3-mt6701.usdz",
        "sha256": "…",
        "bytes": 523409
      }
    },
    "units": "millimeters",
    "up": "+Y",
    "front": "+Z",
    "screenNode": null,
    "parts": [
      {
        "input": "dial-1",
        "node": "Knob",
        "motion": "rotate",
        "axis": [0, 1, 0],
        "pivot": [0, 0, 0],
        "source": "shaftAngle"
      },
      {
        "input": "button-1",
        "node": "ButtonLeft",
        "motion": "translate",
        "axis": [0, -1, 0],
        "travel": 0.6
      },
      {
        "input": "button-2",
        "node": "ButtonRight",
        "motion": "translate",
        "axis": [0, -1, 0],
        "travel": 0.6
      }
    ]
  }
}
```

- This is an illustrative extension, not valid against the current v1 schema.
  Introduce an explicitly versioned contract before publishing it.
- Each `file` sits next to the package under [boards](../boards). The catalog
  pins the package, which pins both assets by digest and byte length. Clients
  download only their platform variant and never execute anything from it.
- Suggested source limits: **2 MiB** per GLB, 100k triangles, textures up to
  2048 px, and no authored animations, cameras, or lights. Establish a separate
  USDZ size/decompressed-resource budget after conversion measurements. Support
  only an explicit, tested extension allowlist shared by both renderers.
  Reject files that exceed the limits and fall back to 2D.
- `node` names must be unique in the GLB. Each listed `input` must be an input
  the device reports; packages cannot invent inputs (same rule as layouts).

## Apple model conversion

Produce the USDZ alongside the GLB during the creator's export/package-build
step. The phone should only download, verify, cache, and display that variant;
ordinary setup and playback must not require a converter or internet access.

1. Validate the GLB, assign stable part IDs, and normalize its hierarchy before
   conversion. Preserve moving parts as separate transformable nodes; never
   merge them into the case or flatten the hierarchy for optimization.
2. Use an evaluated, pinned GLB-to-USD conversion toolchain on a Mac or in the
   package build service. Tool selection needs a working prototype; do not
   assume Apple's tools accept GLB directly or preserve every material.
3. Export USDZ with the same stable part IDs, rest transforms, pivots, and
   control bindings. Record any renamed entity paths in a generated per-asset
   part lookup table; clients bind by stable ID, not display name.
4. Check scale and coordinate conversion explicitly. glTF uses meters;
   dimensions entered in the creator can be millimeters, but motion parameters
   must be converted to each renderer's units. Record USD stage units and test
   that, for example, 0.6 mm button travel is identical in both renderers.
5. Compare both variants with shared fixtures: rest pose, quarter-turn knob,
   359-to-1-degree crossing, full button press, and slider endpoints. Require
   matching part presence, bounds, handedness, and movement direction.
6. Validate the converted archive independently, then publish both digests
   atomically with the package. A failed conversion must block a package being
   marked Apple-ready; retain the last working package and show the error.

Start with a narrow, tested material/extension allowlist shared by both
renderers, rather than promising all `KHR_materials_*` extensions. Converting
materials must not silently drop textures or change transparency.

For private imports, prefer local conversion when available. If conversion
requires a service, explicitly ask before uploading a user's model, explain
retention, and allow cancellation. The creator can save a draft and use the 2D
preview while conversion is unavailable. Imported models are supported, but
cannot bypass the same validation as catalog assets.

## Motion mapping

The board package, not the GLB, defines motion, so models stay plain exports
and one rule set drives every client.

| `motion`   | Fields                   | Driven by                                   |
|------------|--------------------------|---------------------------------------------|
| `rotate`   | `axis`, `pivot`, `source` | Dial: `shaftAngle` (physical) or `output` (mapped value) |
| `translate`| `axis`, `travel` (mm)     | Button: 0 released → `travel` pressed       |
| `slide`    | `axis`, `minimum`, `maximum` (mm) | Slider/analog: normalized 0–1 value |
| `toggle`   | `axis`, `pivot`, `angles` [off, on] | Switch state                       |

- Axes are normalized direction vectors; pivots and travel are in the declared
  authoring units and the node's parent space. Model each part at rest
  (released, 0°). Prefer a dedicated pivot parent at the shaft center, with the
  mesh offset beneath it, so the pivot is `[0, 0, 0]` on both platforms.
- `rotate` with `shaftAngle` follows the knob exactly as the user turns it,
  using the same unwrapped angle already passed to `DeviceBoardPreview.inputAngles`
  so 359° → 1° never spins the long way. Define rotation by the right-hand rule
  around the selected local axis; the creator's direction handle can flip that
  axis to match the physical knob. Do not infer direction from the camera.
- Buttons animate press/release over ~40 ms; holds stay pressed.

## Live data

The data the 2D preview uses is enough; no firmware changes are needed for
knobs:

- Dial angle: Bluetooth live-dial notifications (`0x62`) in low latency mode,
  otherwise control snapshots (`dialAngle`).
- Buttons need live press state. Add read-only `button-N` pressed values to
  the control snapshot, or a compact live-input notification alongside `0x62`
  (for example `0x63`, input index + state), sent only on change.
- When the device is offline, show the model at rest.

## Client integration

1. Add an optional `model` to the shared board package types in
   `device-kit` and the Windows core, with validation (digest, size, unique
   node names, known inputs, finite axes/travel).
2. Extend the board catalog download to fetch and cache the pinned GLB.
3. Add a `DeviceBoardModelView` (SwiftUI wrapping RealityKit with USDZ) and a
   Windows equivalent. It takes the same inputs as `DeviceBoardPreview`
   (layout, inputs, selected input, live angles, button states, `onSelect`)
   so callers can swap between 2D and 3D.
4. Selecting controls: hit-test the tapped node, map it back to its input ID,
   and call `onSelect`, matching the 2D preview.
5. Offer a 2D/3D toggle where the preview appears; default to 2D when no model
   exists, the model fails validation, or the platform cannot render it.
6. Render while interpolation or user camera movement is active, then idle;
   pause when hidden or backgrounded. Measure battery/GPU use rather than
   assuming it matches the 2D preview.

## Guided custom-device creator

Add a **Create custom device** walkthrough to device setup, separate from the
quick path for selecting a known board. It should work without manually editing
JSON, save resumable drafts, and offer Back, Undo/Redo, and Reset for visual
adjustments. Use the same package contract across phone and desktop; conversion
availability must not prevent the phone from authoring a draft.

### 1. Connect and identify

- Discover over BLE/Wi-Fi or enter an address. Read the stable device ID, board
  revision, capabilities, screen dimensions, and input IDs from its descriptor.
- Explain unsupported firmware and offer the existing supported adapter path;
  a creator cannot manufacture capabilities or discover arbitrary GPIO wiring.
- Allow an offline draft with provisional controls, but require reconciliation
  with the real descriptor before activating it on a device.

### 2. Choose a starting point

- Offer the matching catalog definition, a duplicate of an existing definition,
  or a blank design. Preserve exact board/revision matching.
- Let the user keep a simple 2D layout, import GLB, or add a model later. No
  screen and arbitrary supported screen sizes are valid configurations.

### 3. Import and orient the model

- Present a file picker, import progress, and actionable validation errors.
  GLB is the initial import format; 3MF/STEP conversion is a separate future
  importer, not an implicit capability.
- Show an orbitable preview, part tree, isolate/hide controls, and selection
  outlines. Flag single merged meshes that cannot animate separate controls;
  explain how to split them in a modeling tool instead of guessing geometry.
- Set front/up using visual orientation handles. Enter one known physical
  dimension to verify scale. Show a ruler, rest pose, and reset-camera action.

### 4. Identify knobs, buttons, and other controls

- Tap a model part, choose Knob, Button, Slider, Switch, Screen, or Static,
  and assign a device-reported input. Multiple mesh children may share a
  moving parent; prevent conflicting/nested motion bindings.
- Provide **Identify on device**: explicitly enter a safe identification mode,
  then turn a knob or press a button to highlight its input and bind it to the
  selected part. Show ambiguous simultaneous inputs and let the user retry.
- Suppress real remote actions only through a supported device/relay mechanism,
  and restore routing when leaving, disconnecting, or cancelling. If that
  mechanism is unavailable, warn and use manual input selection; do not claim
  that merely hiding actions in the creator prevents the device sending them.

### 5. Adjust visually

- **Knobs:** draggable shaft/pivot and rotation-axis gizmos, clockwise test
  arrow, zero-angle alignment, and a live-turn preview. Use draggable start/end
  arcs for bounded travel, a revolution control for multi-turn, and a clear
  continuous-mode choice. Keep precise numeric fields alongside the handles.
- **Buttons:** choose the press direction with an arrow and drag the pressed
  position to set travel. A press/release test alternates rest and pressed
  poses; keep the rest pose visible as a ghost.
- **Sliders/switches:** drag endpoints or angular limits and scrub a test value.
- **Screens:** select a surface and visually fit its rectangle, orientation,
  and aspect ratio. Start with a test image; live screen mirroring remains a
  separate feature.
- Distinguish **visual model motion** from **actual device settings**. Changing
  a mesh's travel must not change hardware behavior. Applying real dial end
  stops, precision, or jitter uses advertised controls, with explicit Apply,
  error reporting, and readback confirmation.

### 6. Test and generate fallbacks

- Offer simulated motion and live-device mode with an unmistakable label.
  Verify every binding, small turns, wraparound, multi-turn, press/hold/release,
  reconnect, and missing telemetry. Release visual buttons when disconnected;
  do not present simulated or stale state as live.
- Generate a front-view 2D preview and selectable input regions, with manual
  correction. Preserve existing basic geometry if generation is unavailable.
- Convert and preview the Apple USDZ variant, showing which platforms are
  ready. Verify that part selection and motion match the GLB version.

### 7. Save, apply, and optionally share

- Save privately first, scoped to the intended device or exact board/revision.
  Keep model assets on the apps, not in BLE descriptors or firmware profiles.
- Show a summary of controls, model size, platform variants, and any hardware
  settings about to change. Preserve the existing configuration until the new
  package validates and explicit hardware changes are acknowledged.
- Export a portable, digest-verified package including GLB, USDZ, mappings, and
  2D fallback. Sharing to GitHub is an optional reviewed contribution, never an
  automatic upload. Exclude tokens, addresses, Wi-Fi credentials, and telemetry.

### Implementation phases and acceptance criteria

1. **Contract and conversion proof:** versioned schema, stable part IDs,
   independent asset validation, and a knob/two-button fixture rendered in
   GLB and USDZ. Reject external asset URLs, archive traversal, oversized
   decoded textures, and unsupported required extensions.
2. **Runtime preview:** optional 3D views on Apple and Windows, part selection,
   live motion, offline cache, visible failure reporting, and reliable 2D
   fallback. Add explicit button state telemetry with snapshot/reconnect
   resynchronization; choose an opcode only after protocol review.
3. **Creator:** complete the walkthrough, private imports, visual handles,
   persisted drafts, undo, and verified device-setting writes.
4. **Package export/catalog:** reproducible conversion provenance, atomic
   publication, rollback, and documentation for contributors.

Completion means a user can import a knob-and-two-button GLB, identify all
three inputs, adjust their axes/travel without JSON, save/reopen a draft,
generate the Apple variant, and see equivalent live behavior on phone and
desktop. Test failed conversion/download, offline use, permission denial,
reconnect during a press, and cancelling setup without losing prior settings.

## Authoring checklist

1. Export each moving part (knob, each button, slider thumb) as its own named
   object; keep the case and static parts separate or merged.
2. Set each moving part's origin on its rotation/press axis, at rest position.
3. Author at a verified physical scale, +Y up, +Z toward the user. Export glTF
   geometry in meters and declare millimeter motion parameters explicitly.
4. Export GLB with applied scale, no animations, and compressed textures.
5. Use the creator to map inputs and motion, generate USDZ, pin both assets in
   the package, and run catalog validation and cross-platform motion tests.

## Open questions

- Windows renderer choice (native D3D versus WebView2) trades package size
  against implementation effort.
- Whether to show the device's screen contents on `screenNode` as a live
  texture, or leave screens as static materials.
- Which GLB-to-USDZ toolchain meets the hierarchy/material requirements, and
  where phone-initiated conversion runs when no Mac is available.
