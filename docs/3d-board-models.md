# 3D board models (design proposal)

Status: **not implemented**. This describes how board packages could add an
optional, animated 3D model of a device whose knobs turn and buttons press in
step with the real hardware. Boards without a model keep the existing 2D
layout and artwork described in [custom-devices.md](custom-devices.md#board-layout-packages).

## Why GLB

- **GLB** (binary glTF 2.0) is a runtime format: one file holding meshes,
  materials, textures, and a named node hierarchy, with per-node transforms.
  Every client platform can render it:
  - iPhone/iPad and Mac: SceneKit or RealityKit. Neither loads glTF natively,
    so use a small loader such as GLTFKit2 (glTF → SceneKit nodes), or convert
    to USDZ when the package is built.
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
    "file": "supermini-s3-mt6701.glb",
    "sha256": "…",
    "bytes": 412337,
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

- `file` sits next to the package under [boards](../boards); the index entry
  pins it like the JSON package. Clients download and cache it with the same
  digest check and never execute anything from it.
- Suggested limits: **2 MiB** per GLB, 100k triangles, textures up to 2048 px,
  no animations, cameras, lights, or extensions other than
  `KHR_materials_*`, `KHR_texture_transform`, and `KHR_mesh_quantization`.
  Reject files that exceed them and fall back to 2D.
- `node` names must be unique in the GLB. Each listed `input` must be an input
  the device reports; packages cannot invent inputs (same rule as layouts).

## Motion mapping

The board package, not the GLB, defines motion, so models stay plain exports
and one rule set drives every client.

| `motion`   | Fields                   | Driven by                                   |
|------------|--------------------------|---------------------------------------------|
| `rotate`   | `axis`, `pivot`, `source` | Dial: `shaftAngle` (physical) or `output` (mapped value) |
| `translate`| `axis`, `travel` (mm)     | Button: 0 released → `travel` pressed       |
| `slide`    | `axis`, `minimum`, `maximum` (mm) | Slider/analog: normalized 0–1 value |
| `toggle`   | `axis`, `pivot`, `angles` [off, on] | Switch state                       |

- Axes and pivots are in the node's parent space, in `units`. Model each part
  at rest (released, 0°) with its origin on the shaft or press axis; then the
  pivot is usually `[0, 0, 0]`.
- `rotate` with `shaftAngle` follows the knob exactly as the user turns it,
  using the same unwrapped angle already passed to `DeviceBoardPreview.inputAngles`
  so 359° → 1° never spins the long way. Positive angles turn clockwise viewed
  from `front`.
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
3. Add a `DeviceBoardModelView` (SwiftUI wrapping SceneKit/RealityKit) and a
   Windows equivalent. It takes the same inputs as `DeviceBoardPreview`
   (layout, inputs, selected input, live angles, button states, `onSelect`)
   so callers can swap between 2D and 3D.
4. Selecting controls: hit-test the tapped node, map it back to its input ID,
   and call `onSelect`, matching the 2D preview.
5. Offer a 2D/3D toggle where the preview appears; default to 2D when no model
   exists, the model fails validation, or the platform cannot render it.
6. Render on demand: redraw only when an input value changes or the user
   orbits the view, to keep battery use close to the 2D preview.

## Authoring checklist

1. Export each moving part (knob, each button, slider thumb) as its own named
   object; keep the case and static parts separate or merged.
2. Set each moving part's origin on its rotation/press axis, at rest position.
3. Use millimeters, +Y up, +Z toward the user (or declare otherwise).
4. Export GLB with applied scale, no animations, and compressed textures.
5. Add the `model` block, pin the GLB in the index, and run the catalog
   validation and client tests.

## Open questions

- Windows renderer choice (native D3D versus WebView2) trades package size
  against implementation effort.
- Whether to show the device's screen contents on `screenNode` as a live
  texture, or leave screens as static materials.
- Whether user-supplied models (not from the catalog) should be allowed, with
  the same validation.
