# Signal — SwiftUI

Open `Loaders.xcodeproj` and press Run. The app is a gallery of the loader; tap one for a bigger view and the line of code that draws it.

## Using it in your own app

Drag the `LoaderKit` files into your target, then:

```swift
Loader(.signal)
```

Everything else is optional and defaulted:

```swift
Loader(.signal, color: .indigo, size: 72, speed: 1.4)
```

| Parameter | Default | What it does |
| --- | --- | --- |
| `color` | `.primary` | The moving part. |
| `track` | `.primary` | The static chrome the mechanism sits in. |
| `background` | system background | Shows through the two loaders that punch a hole. |
| `size` | `96` | Edge of the square. The design is scaled, not re-laid-out. |
| `speed` | `1.5` | `2` is twice as fast. |
| `scheme` | the system's | Pin `.light` or `.dark` instead of following the device. |
| `time` | live | Pin the clock, for snapshots and previews. |
| `label` | `"Loading"` | VoiceOver label; pass `nil` to hide it. |

## Light and dark

Nothing to do. `color` and `track` default to `Color.primary`, so a loader is
white on a dark screen and black on a light one. Pass a colour and it is used in
both appearances; pass a dynamic `Color` and it resolves per appearance as usual.

## What is inside

```
LoaderSpec.swift        the model: shapes, paints, keyframes
LoaderPath.swift        SVG path parsing, rounded rects, path sampling
LoaderAnimation.swift   the keyframe evaluator
LoaderEngine.swift      the Canvas renderer
Loader.swift            the view
LoaderCatalog.swift     Signal, as data
LoaderName.swift        the name enum
```

Drawing is a single `Canvas` inside a `TimelineView`, so a loader is one view
and one draw call per frame no matter how many pieces it has.
