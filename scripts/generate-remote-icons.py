#!/usr/bin/env python3
"""Generate the M5Paper and editor remote icon outlines from vendored Phosphor SVGs.

Usage: scripts/generate-remote-icons.py [--download]
"""
import argparse
import math
import re
import sys
import urllib.request
import xml.etree.ElementTree as ElementTree
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "assets" / "remote-icons" / "phosphor"
PHOSPHOR_VERSION = "2.1.1"
PHOSPHOR_URL = f"https://unpkg.com/@phosphor-icons/core@{PHOSPHOR_VERSION}"

FIRMWARE_OUTPUT = ROOT / "firmware" / "include" / "remote_icon_glyphs.h"
SWIFT_OUTPUTS = [
    ROOT / "mac-companion" / "Sources" / "PaperGIFMac" / "RemoteIconGlyphs.swift",
    ROOT / "paperGIF" / "RemoteIconGlyphs.swift",
]
CSHARP_OUTPUT = ROOT / "windows-companion" / "src" / "PaperGIF.Windows.Host" / "RemoteIconGlyphs.cs"

# Profile symbol names keep their SF Symbols spelling so existing profiles still resolve.
ICONS = [
    ("circle.fill", "circle-fill"),
    ("play.fill", "play-fill"),
    ("pause.fill", "pause-fill"),
    ("playpause.fill", "play-pause-fill"),
    ("stop.fill", "stop-fill"),
    ("backward.fill", "rewind-fill"),
    ("forward.fill", "fast-forward-fill"),
    ("speaker.fill", "speaker-simple-none-fill"),
    ("speaker.wave.2.fill", "speaker-simple-high-fill"),
    ("speaker.slash.fill", "speaker-simple-slash-fill"),
    ("power", "power-bold"),
    ("lightbulb.fill", "lightbulb-fill"),
    ("sun.max.fill", "sun-fill"),
    ("snowflake", "snowflake-bold"),
    ("drop.fill", "drop-fill"),
    ("humidity.fill", "drop-half-bottom-fill"),
    ("thermometer.medium", "thermometer-simple-fill"),
    ("fan.fill", "fan-fill"),
    ("wind", "wind-bold"),
    ("moon.fill", "moon-fill"),
    ("sparkles", "sparkle-fill"),
    ("house.fill", "house-fill"),
    ("gearshape.fill", "gear-six-fill"),
    ("arrow.up", "arrow-up-bold"),
    ("arrow.down", "arrow-down-bold"),
    ("arrow.left", "arrow-left-bold"),
    ("arrow.right", "arrow-right-bold"),
    ("arrow.up.left", "arrow-up-left-bold"),
    ("arrow.up.right", "arrow-up-right-bold"),
    ("arrow.down.left", "arrow-down-left-bold"),
    ("arrow.down.right", "arrow-down-right-bold"),
    ("plus", "plus-bold"),
    ("minus", "minus-bold"),
    ("checkmark", "check-bold"),
    ("xmark", "x-bold"),
    ("star.fill", "star-fill"),
    ("heart.fill", "heart-fill"),
    ("bolt.fill", "lightning-fill"),
    ("lock.fill", "lock-simple-fill"),
    ("lock.open.fill", "lock-simple-open-fill"),
    ("wifi", "wifi-high-bold"),
    ("slider.horizontal.3", "sliders-horizontal-bold"),
    ("music.note", "music-note-simple-fill"),
    ("display", "monitor-fill"),
    ("powerplug.fill", "plug-fill"),
    ("scope", "crosshair-simple-bold"),
    ("move.3d", "arrows-out-cardinal-bold"),
]

VIEWBOX = 256.0
# Trimming Phosphor's margin keeps icons legible at small sizes; overflowing icons are nudged inside.
CROP = 8.0
UNITS = VIEWBOX - 2 * CROP
FIXED_SCALE = 16
FLATNESS = 0.3
NUMBER = re.compile(r"[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?")
SVG_NAMESPACE = "{http://www.w3.org/2000/svg}"


def weight_of(name):
    suffix = name.rsplit("-", 1)[-1]
    return suffix if suffix in ("fill", "bold", "thin", "light", "duotone") else "regular"


def download():
    SOURCE.mkdir(parents=True, exist_ok=True)
    targets = [(f"{PHOSPHOR_URL}/LICENSE", SOURCE / "LICENSE")]
    targets += [
        (f"{PHOSPHOR_URL}/assets/{weight_of(name)}/{name}.svg", SOURCE / f"{name}.svg")
        for _, name in ICONS
    ]
    for url, destination in targets:
        if destination.exists():
            continue
        with urllib.request.urlopen(url, timeout=20) as response:
            destination.write_bytes(response.read())
        print(f"downloaded {destination.relative_to(ROOT)}")


class Scanner:
    def __init__(self, data):
        self.data = data
        self.index = 0

    def skip(self):
        while self.index < len(self.data) and self.data[self.index] in " ,\t\r\n":
            self.index += 1

    def at_end(self):
        self.skip()
        return self.index >= len(self.data)

    def peek_command(self):
        self.skip()
        if self.index < len(self.data) and self.data[self.index].isalpha():
            return self.data[self.index]
        return None

    def number(self):
        self.skip()
        match = NUMBER.match(self.data, self.index)
        if not match:
            raise ValueError(f"expected number at {self.index}: {self.data[self.index:self.index + 16]!r}")
        self.index = match.end()
        return float(match.group())

    def flag(self):
        self.skip()
        character = self.data[self.index]
        if character not in "01":
            raise ValueError(f"expected arc flag at {self.index}")
        self.index += 1
        return character == "1"


def arc_to_cubics(start, rx, ry, rotation, large, sweep, end):
    if start == end:
        return []
    rx, ry = abs(rx), abs(ry)
    if rx == 0 or ry == 0:
        return [("L", end)]
    phi = math.radians(rotation)
    cos_phi, sin_phi = math.cos(phi), math.sin(phi)
    dx, dy = (start[0] - end[0]) / 2, (start[1] - end[1]) / 2
    x1 = cos_phi * dx + sin_phi * dy
    y1 = -sin_phi * dx + cos_phi * dy
    radii = x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry)
    if radii > 1:
        rx *= math.sqrt(radii)
        ry *= math.sqrt(radii)
    numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
    denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
    coefficient = math.sqrt(max(0.0, numerator / denominator))
    if large == sweep:
        coefficient = -coefficient
    center_x1 = coefficient * rx * y1 / ry
    center_y1 = -coefficient * ry * x1 / rx
    center_x = cos_phi * center_x1 - sin_phi * center_y1 + (start[0] + end[0]) / 2
    center_y = sin_phi * center_x1 + cos_phi * center_y1 + (start[1] + end[1]) / 2

    def angle(ux, uy, vx, vy):
        return math.atan2(ux * vy - uy * vx, ux * vx + uy * vy)

    theta = angle(1, 0, (x1 - center_x1) / rx, (y1 - center_y1) / ry)
    delta = angle((x1 - center_x1) / rx, (y1 - center_y1) / ry,
                  (-x1 - center_x1) / rx, (-y1 - center_y1) / ry)
    if not sweep and delta > 0:
        delta -= 2 * math.pi
    elif sweep and delta < 0:
        delta += 2 * math.pi
    count = max(1, math.ceil(abs(delta) / (math.pi / 2) - 1e-9))
    step = delta / count
    handle = 4 / 3 * math.tan(step / 4)

    def point(value):
        return (center_x + cos_phi * rx * math.cos(value) - sin_phi * ry * math.sin(value),
                center_y + sin_phi * rx * math.cos(value) + cos_phi * ry * math.sin(value))

    def derivative(value):
        return (-cos_phi * rx * math.sin(value) - sin_phi * ry * math.cos(value),
                -sin_phi * rx * math.sin(value) + cos_phi * ry * math.cos(value))

    segments = []
    for index in range(count):
        first = theta + index * step
        second = first + step
        p0, p3 = point(first), point(second)
        d0, d3 = derivative(first), derivative(second)
        if index == count - 1:
            p3 = end
        segments.append(("C", (p0[0] + handle * d0[0], p0[1] + handle * d0[1]),
                         (p3[0] - handle * d3[0], p3[1] - handle * d3[1]), p3))
    return segments


def parse_path(data):
    """Returns contours as (start, [("L", p) | ("C", c1, c2, p)])."""
    scanner = Scanner(data)
    contours = []
    current = (0.0, 0.0)
    start = current
    command = None
    previous = None
    cubic_control = None
    quad_control = None
    open_contour = None

    def segments():
        nonlocal open_contour
        if open_contour is None:
            open_contour = (current, [])
            contours.append(open_contour)
        return open_contour[1]

    while not scanner.at_end():
        explicit = scanner.peek_command()
        if explicit:
            scanner.index += 1
            command = explicit
        elif command is None:
            raise ValueError("path data must start with a command")
        elif command in "Mm":
            command = "L" if command == "M" else "l"
        elif command in "Zz":
            raise ValueError("numbers cannot follow a close-path command")
        relative = command.islower()
        kind = command.upper()

        def read_point():
            x, y = scanner.number(), scanner.number()
            return (current[0] + x, current[1] + y) if relative else (x, y)

        if kind == "M":
            current = read_point()
            start = current
            open_contour = (current, [])
            contours.append(open_contour)
        elif kind == "Z":
            open_contour = None
            current = start
        elif kind == "L":
            current = read_point()
            segments().append(("L", current))
        elif kind == "H":
            x = scanner.number()
            current = (current[0] + x if relative else x, current[1])
            segments().append(("L", current))
        elif kind == "V":
            y = scanner.number()
            current = (current[0], current[1] + y if relative else y)
            segments().append(("L", current))
        elif kind in "CS":
            if kind == "C":
                first = read_point()
            elif previous in ("C", "S") and cubic_control:
                first = (2 * current[0] - cubic_control[0], 2 * current[1] - cubic_control[1])
            else:
                first = current
            second = read_point()
            end = read_point()
            segments().append(("C", first, second, end))
            cubic_control = second
            current = end
        elif kind in "QT":
            if kind == "Q":
                control = read_point()
            elif previous in ("Q", "T") and quad_control:
                control = (2 * current[0] - quad_control[0], 2 * current[1] - quad_control[1])
            else:
                control = current
            end = read_point()
            segments().append(("C",
                               (current[0] + 2 / 3 * (control[0] - current[0]),
                                current[1] + 2 / 3 * (control[1] - current[1])),
                               (end[0] + 2 / 3 * (control[0] - end[0]),
                                end[1] + 2 / 3 * (control[1] - end[1])),
                               end))
            quad_control = control
            current = end
        elif kind == "A":
            rx, ry, rotation = scanner.number(), scanner.number(), scanner.number()
            large, sweep = scanner.flag(), scanner.flag()
            end = read_point()
            segments().extend(arc_to_cubics(current, rx, ry, rotation, large, sweep, end))
            current = end
        else:
            raise ValueError(f"unsupported path command {command}")
        previous = kind
    return [contour for contour in contours if contour[1]]


def load_icon(name):
    root = ElementTree.parse(SOURCE / f"{name}.svg").getroot()
    if root.get("viewBox") != "0 0 256 256":
        raise ValueError(f"{name}: unexpected viewBox {root.get('viewBox')}")
    contours = []
    for element in root.iter():
        tag = element.tag.replace(SVG_NAMESPACE, "")
        if tag in ("svg", "title"):
            continue
        if tag != "path" or element.get("transform") or element.get("fill-rule") == "evenodd":
            raise ValueError(f"{name}: unsupported element {tag} {element.attrib}")
        contours += parse_path(element.get("d"))

    def crop(point):
        return (point[0] - CROP, point[1] - CROP)

    cropped = []
    for start, segments in contours:
        converted = []
        for segment in segments:
            converted.append((segment[0],) + tuple(crop(point) for point in segment[1:]))
        cropped.append((crop(start), converted))
    return cropped


def flatten(contours):
    polygons = []
    for start, segments in contours:
        points = [start]
        current = start
        for segment in segments:
            if segment[0] == "L":
                points.append(segment[1])
            else:
                subdivide(current, segment[1], segment[2], segment[3], points, 0)
            current = segment[-1]
        polygons.append(points)
    return polygons


def subdivide(p0, p1, p2, p3, output, depth):
    dx, dy = p3[0] - p0[0], p3[1] - p0[1]
    length = math.hypot(dx, dy)
    if length > 1e-9:
        distance = max(abs((p[0] - p0[0]) * dy - (p[1] - p0[1]) * dx) / length for p in (p1, p2))
    else:
        distance = max(math.hypot(p[0] - p0[0], p[1] - p0[1]) for p in (p1, p2))
    if distance <= FLATNESS or depth >= 12:
        output.append(p3)
        return
    def mid(a, b):
        return ((a[0] + b[0]) / 2, (a[1] + b[1]) / 2)
    p01, p12, p23 = mid(p0, p1), mid(p1, p2), mid(p2, p3)
    p012, p123 = mid(p01, p12), mid(p12, p23)
    center = mid(p012, p123)
    subdivide(p0, p01, p012, center, output, depth + 1)
    subdivide(center, p123, p23, p3, output, depth + 1)


def fit_inside(contours):
    points = [point for polygon in flatten(contours) for point in polygon]

    def shift(low, high):
        return -low if low < 0 else UNITS - high if high > UNITS else 0.0

    dx = shift(min(p[0] for p in points), max(p[0] for p in points))
    dy = shift(min(p[1] for p in points), max(p[1] for p in points))
    if dx == 0 and dy == 0:
        return contours

    def move(point):
        return (point[0] + dx, point[1] + dy)

    return [(move(start), [(segment[0],) + tuple(move(p) for p in segment[1:]) for segment in segments])
            for start, segments in contours]


def fixed_polygons(polygons, symbol):
    limit = int(UNITS * FIXED_SCALE)
    result = []
    for polygon in polygons:
        fixed = []
        for x, y in polygon:
            point = (round(x * FIXED_SCALE), round(y * FIXED_SCALE))
            if not (-FIXED_SCALE <= point[0] <= limit + FIXED_SCALE and
                    -FIXED_SCALE <= point[1] <= limit + FIXED_SCALE):
                raise ValueError(f"{symbol}: point {x:.2f},{y:.2f} lies outside the cropped icon box")
            if not fixed or fixed[-1] != point:
                fixed.append(point)
        while len(fixed) > 1 and fixed[-1] == fixed[0]:
            fixed.pop()
        if len(fixed) >= 3:
            result.append(fixed)
    return result


def format_number(value):
    text = f"{value:.2f}".rstrip("0").rstrip(".")
    return "0" if text in ("-0", "") else text


def outline_string(contours):
    parts = []
    for start, segments in contours:
        parts += ["M", format_number(start[0]), format_number(start[1])]
        for segment in segments:
            parts.append(segment[0])
            for point in segment[1:]:
                parts += [format_number(point[0]), format_number(point[1])]
        parts.append("Z")
    return " ".join(parts)


def wrap_values(values, indent="    ", width=100):
    lines, line = [], indent
    for value in values:
        text = f"{value},"
        if len(line) + len(text) + 1 > width and line.strip():
            lines.append(line.rstrip())
            line = indent
        line += text + " "
    if line.strip():
        lines.append(line.rstrip())
    return "\n".join(lines)


HEADER_NOTE = (
    "Generated by scripts/generate-remote-icons.py from Phosphor Icons "
    f"{PHOSPHOR_VERSION} (MIT, assets/remote-icons/phosphor/LICENSE). Do not edit."
)


def firmware_source(icons):
    points, lengths, glyphs = [], [], []
    for symbol, polygons in icons:
        glyphs.append((symbol, len(points) // 2, len(lengths), len(polygons)))
        for polygon in polygons:
            lengths.append(len(polygon))
            for x, y in polygon:
                points += [x, y]
    glyph_lines = "\n".join(
        f'    {{"{symbol}", {first_point}, {first_contour}, {count}}},'
        for symbol, first_point, first_contour, count in glyphs
    )
    return f"""// {HEADER_NOTE}
#pragma once

#include <cstddef>
#include <cstdint>

namespace remote_icons {{

struct Glyph {{
    const char* name;
    uint32_t firstPoint;
    uint16_t firstContour;
    uint16_t contourCount;
}};

// Closed polygon outlines on a {int(UNITS * FIXED_SCALE)}-unit square, y down.
constexpr int32_t kGlyphUnits = {int(UNITS * FIXED_SCALE)};

static const int16_t kGlyphPoints[] = {{
{wrap_values(points)}
}};

static const uint16_t kGlyphContourLengths[] = {{
{wrap_values(lengths)}
}};

static const Glyph kGlyphs[] = {{
{glyph_lines}
}};

constexpr size_t kGlyphCount = sizeof(kGlyphs) / sizeof(kGlyphs[0]);

}}  // namespace remote_icons
"""


def swift_source(outlines):
    entries = "\n".join(f'        "{symbol}": "{outline}",' for symbol, outline in outlines)
    return f"""// {HEADER_NOTE}
import CoreGraphics
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// The exact icon outlines the M5Paper draws, keyed by profile symbol name.
enum RemoteIconGlyphs {{
    static func contains(_ name: String) -> Bool {{
        outlines[name] != nil
    }}

    /// Returns the outline in a unit square with y pointing down.
    static func path(named name: String) -> CGPath? {{
        guard let outline = outlines[name] else {{ return nil }}
        let tokens = outline.split(separator: " ")
        let path = CGMutablePath()
        var index = 0
        func point() -> CGPoint {{
            defer {{ index += 2 }}
            return CGPoint(x: (Double(tokens[index]) ?? 0) / units, y: (Double(tokens[index + 1]) ?? 0) / units)
        }}
        while index < tokens.count {{
            let command = tokens[index]
            index += 1
            switch command {{
            case "M": path.move(to: point())
            case "L": path.addLine(to: point())
            case "C":
                let first = point()
                let second = point()
                path.addCurve(to: point(), control1: first, control2: second)
            default: path.closeSubpath()
            }}
        }}
        return path
    }}

#if canImport(AppKit)
    static func templateImage(named name: String, size: CGFloat) -> NSImage? {{
        guard let glyph = path(named: name) else {{ return nil }}
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) {{ rect in
            guard let context = NSGraphicsContext.current?.cgContext else {{ return false }}
            context.scaleBy(x: rect.width, y: rect.height)
            context.addPath(glyph)
            context.setFillColor(.black)
            context.fillPath()
            return true
        }}
        image.isTemplate = true
        return image
    }}
#endif

    private static let units = {format_number(UNITS)}.0
    private static let outlines: [String: String] = [
{entries}
    ]
}}

struct RemoteIconGlyphShape: Shape {{
    let name: String

    func path(in rect: CGRect) -> Path {{
        guard let glyph = RemoteIconGlyphs.path(named: name) else {{ return Path() }}
        let side = min(rect.width, rect.height)
        var transform = CGAffineTransform(translationX: rect.midX - side / 2, y: rect.midY - side / 2)
            .scaledBy(x: side, y: side)
        return Path(glyph.copy(using: &transform) ?? glyph)
    }}
}}

/// Draws the device icon, falling back to the SF Symbol for names the M5Paper cannot draw.
struct RemoteIconGlyphView: View {{
    let name: String

    var body: some View {{
        if RemoteIconGlyphs.contains(name) {{
            RemoteIconGlyphShape(name: name)
                .aspectRatio(1, contentMode: .fit)
        }} else if !name.isEmpty {{
            Image(systemName: name)
                .resizable()
                .scaledToFit()
        }}
    }}
}}
"""


def csharp_source(outlines):
    entries = "\n".join(f'        ["{symbol}"] = "{outline}",' for symbol, outline in outlines)
    return f"""// {HEADER_NOTE}
using System.Drawing.Drawing2D;
using System.Globalization;

namespace PaperGIF.Windows.Host;

/// <summary>The exact icon outlines the M5Paper draws, keyed by profile symbol name.</summary>
internal static class RemoteIconGlyphs
{{
    private const float Units = {format_number(UNITS)}f;

    public static IReadOnlyCollection<string> Names => Outlines.Keys;

    public static bool Contains(string? name) => name is not null && Outlines.ContainsKey(name);

    public static GraphicsPath? CreatePath(string? name, RectangleF bounds)
    {{
        if (name is null || !Outlines.TryGetValue(name, out var outline))
        {{
            return null;
        }}
        var side = Math.Min(bounds.Width, bounds.Height);
        var left = bounds.Left + (bounds.Width - side) / 2;
        var top = bounds.Top + (bounds.Height - side) / 2;
        var tokens = outline.Split(' ');
        var path = new GraphicsPath(FillMode.Winding);
        var index = 0;
        var current = PointF.Empty;
        PointF Next()
        {{
            var point = new PointF(
                left + float.Parse(tokens[index], CultureInfo.InvariantCulture) * side / Units,
                top + float.Parse(tokens[index + 1], CultureInfo.InvariantCulture) * side / Units);
            index += 2;
            return point;
        }}
        while (index < tokens.Length)
        {{
            switch (tokens[index++])
            {{
                case "M":
                    path.StartFigure();
                    current = Next();
                    break;
                case "L":
                    var end = Next();
                    path.AddLine(current, end);
                    current = end;
                    break;
                case "C":
                    var first = Next();
                    var second = Next();
                    var target = Next();
                    path.AddBezier(current, first, second, target);
                    current = target;
                    break;
                default:
                    path.CloseFigure();
                    break;
            }}
        }}
        return path;
    }}

    private static readonly Dictionary<string, string> Outlines = new(StringComparer.Ordinal)
    {{
{entries}
    }};
}}
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--download", action="store_true", help="fetch missing Phosphor SVGs first")
    arguments = parser.parse_args()
    if arguments.download:
        download()
    firmware_icons, outlines = [], []
    for symbol, name in ICONS:
        contours = fit_inside(load_icon(name))
        firmware_icons.append((symbol, fixed_polygons(flatten(contours), symbol)))
        outlines.append((symbol, outline_string(contours)))
    FIRMWARE_OUTPUT.write_text(firmware_source(firmware_icons))
    for output in SWIFT_OUTPUTS:
        output.write_text(swift_source(outlines))
    CSHARP_OUTPUT.write_text(csharp_source(outlines))
    point_count = sum(len(polygon) for _, polygons in firmware_icons for polygon in polygons)
    print(f"{len(ICONS)} icons, {point_count} firmware points ({point_count * 4} bytes)")


if __name__ == "__main__":
    sys.exit(main())
