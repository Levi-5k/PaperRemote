import CoreGraphics
import Foundation

/// Grayscale source images for button textures, in the M5Paper's PBGI format:
/// "PBGI", version 1, reserved, little-endian width and height, then 8-bit luminance rows.
enum PaperGIFButtonImageStore {
    struct Image: Sendable {
        let width: Int
        let height: Int
        let pixels: [UInt8]
    }

    nonisolated static let maximumSide = 400
    nonisolated private static let headerBytes = 10

    nonisolated static func makeImageFile(from mediaData: Data) throws -> Data {
        let source = try PaperGIFEncoder.previewImage(from: mediaData)
        let scale = min(1, Double(maximumSide) / Double(max(source.width, source.height)))
        let width = max(1, Int((Double(source.width) * scale).rounded()))
        let height = max(1, Int((Double(source.height) * scale).rounded()))
        var pixels = [UInt8](repeating: 255, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            context.interpolationQuality = .high
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(bounds)
            context.draw(source, in: bounds)
            return true
        }
        guard drawn else { throw PaperGIFError.imageRenderFailed }
        var output = Data("PBGI".utf8)
        output.append(contentsOf: [1, 0])
        output.append(contentsOf: [UInt8(width & 0xFF), UInt8(width >> 8), UInt8(height & 0xFF), UInt8(height >> 8)])
        output.append(contentsOf: pixels)
        return output
    }

    nonisolated static func decode(_ data: Data) -> Image? {
        let bytes = [UInt8](data)
        guard bytes.count >= headerBytes,
              bytes[0..<4].elementsEqual("PBGI".utf8),
              bytes[4] == 1 else { return nil }
        let width = Int(bytes[6]) | Int(bytes[7]) << 8
        let height = Int(bytes[8]) | Int(bytes[9]) << 8
        guard width > 0, height > 0, width <= 540, height <= 540,
              bytes.count == headerBytes + width * height else { return nil }
        return Image(width: width, height: height, pixels: Array(bytes[headerBytes...]))
    }

    nonisolated static func save(_ data: Data, id: UUID) throws {
        try data.write(to: try fileURL(for: id), options: .atomic)
    }

    nonisolated static func load(_ id: UUID) -> Data? {
        guard let url = try? fileURL(for: id) else { return nil }
        return try? Data(contentsOf: url)
    }

    nonisolated private static func fileURL(for id: UUID) throws -> URL {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("paperGIF-v2", isDirectory: true)
        .appendingPathComponent("ButtonImages", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(id.uuidString).pbgi")
    }
}

extension PaperGIFRemoteButtonBackground {
    /// Idle fill and label luminance; matches firmware remote_button_style.h.
    var idleFillLuminance: Int {
        switch self {
        case .outline, .borderless: 255
        case .filled: 0
        case .shaded: 195
        }
    }

    var idleForegroundLuminance: Int { self == .filled ? 255 : 0 }
    var hasIdleBorder: Bool { self == .outline }
}

/// Swift twin of firmware remote_button_texture.h, used for editor previews.
enum PaperGIFButtonTextureRenderer {
    private struct CacheKey: Hashable {
        let texture: PaperGIFRemoteButtonTexture
        let background: PaperGIFRemoteButtonBackground
        let width: Int
        let height: Int
        let radius: Int
    }

    @MainActor private static var cache: [CacheKey: CGImage] = [:]
    @MainActor private static var images: [UUID: PaperGIFButtonImageStore.Image] = [:]

    @MainActor static func image(
        texture: PaperGIFRemoteButtonTexture,
        background: PaperGIFRemoteButtonBackground,
        width: Int,
        height: Int,
        radius: Int
    ) -> CGImage? {
        guard texture.kind != .none, width > 0, height > 0 else { return nil }
        let key = CacheKey(texture: texture, background: background, width: width, height: height, radius: radius)
        if let cached = cache[key] { return cached }
        var source: PaperGIFButtonImageStore.Image?
        if texture.kind == .image {
            guard let id = texture.imageID else { return nil }
            if images[id] == nil {
                images[id] = PaperGIFButtonImageStore.load(id).flatMap(PaperGIFButtonImageStore.decode)
            }
            guard let loaded = images[id] else { return nil }
            source = loaded
        }
        guard let rendered = render(
            texture: texture,
            source: source,
            fill: background.idleFillLuminance,
            foreground: background.idleForegroundLuminance,
            width: width,
            height: height,
            radius: radius
        ) else { return nil }
        if cache.count > 96 { cache.removeAll() }
        cache[key] = rendered
        return rendered
    }

    nonisolated static func render(
        texture: PaperGIFRemoteButtonTexture,
        source: PaperGIFButtonImageStore.Image?,
        fill: Int,
        foreground: Int,
        width: Int,
        height: Int,
        radius: Int
    ) -> CGImage? {
        let inkPercent = Float(100 - min(100, max(0, texture.fade)))
        func composite(_ ink: Float) -> Int {
            fill + Int((Float(foreground - fill) * ink * inkPercent / 100).rounded())
        }
        var levels = [UInt8](repeating: 15, count: width * height)
        if texture.kind == .image, let source {
            let sampler = CoverSampler(image: source, width: width, height: height)
            var luminance = [UInt8](repeating: 255, count: width * height)
            for y in 0..<height {
                for x in 0..<width {
                    let darkness = Float(255 - Int(sampler.sample(x: x, y: y))) / 255
                    luminance[y * width + x] = UInt8(clamping: composite(darkness))
                }
            }
            let packed = PaperGIFEncoder.quantizedLuminance(
                luminance,
                width: width,
                monochromeMode: texture.mode,
                threshold: UInt8(clamping: texture.threshold),
                monochromeLevels: texture.levels,
                halftoneDotSpacing: texture.dotSpacing,
                halftoneAngle: texture.angle,
                halftoneDotGain: texture.dotGain
            )
            let grayscale = PaperGIFEncoder.quantizesToGrayscale(
                monochromeMode: texture.mode, monochromeLevels: texture.levels
            )
            let bytesPerRow = grayscale ? (width + 1) / 2 : (width + 7) / 8
            for y in 0..<height {
                for x in 0..<width {
                    if grayscale {
                        let byte = packed[y * bytesPerRow + x / 2]
                        levels[y * width + x] = x.isMultiple(of: 2) ? byte >> 4 : byte & 0x0F
                    } else {
                        let black = packed[y * bytesPerRow + x / 8] & (0x80 >> UInt8(x % 8)) != 0
                        levels[y * width + x] = black ? 0 : 15
                    }
                }
            }
        } else if texture.kind == .pattern {
            let spacing = Float(max(2, texture.scale))
            let lineWidth = max(1, texture.lineWidth)
            let offset: Float = lineWidth.isMultiple(of: 2) ? 0.5 : 0
            for y in 0..<height {
                for x in 0..<width {
                    let ink = patternCoverage(
                        texture.pattern,
                        x: Float(x - width / 2) + offset,
                        y: Float(y - height / 2) + offset,
                        spacing: spacing,
                        lineWidth: Float(lineWidth)
                    )
                    levels[y * width + x] = UInt8((composite(ink) * 15 + 127) / 255)
                }
            }
        } else {
            return nil
        }
        var gray = [UInt8](repeating: 255, count: width * height)
        for y in 0..<height {
            for x in 0..<width where insideRoundedRect(x: x, y: y, width: width, height: height, radius: radius) {
                gray[y * width + x] = levels[y * width + x] * 17
            }
        }
        guard let provider = CGDataProvider(data: Data(gray) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: [],
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private struct CoverSampler {
        let image: PaperGIFButtonImageStore.Image
        let width: Int
        let height: Int
        let cropX: Int
        let cropY: Int
        let cropWidth: Int
        let cropHeight: Int

        init(image: PaperGIFButtonImageStore.Image, width: Int, height: Int) {
            self.image = image
            self.width = width
            self.height = height
            var cropWidth: Int
            var cropHeight: Int
            if image.width * height > image.height * width {
                cropHeight = image.height
                cropWidth = (image.height * width + height / 2) / height
            } else {
                cropWidth = image.width
                cropHeight = (image.width * height + width / 2) / width
            }
            cropWidth = min(max(cropWidth, 1), image.width)
            cropHeight = min(max(cropHeight, 1), image.height)
            self.cropWidth = cropWidth
            self.cropHeight = cropHeight
            cropX = (image.width - cropWidth) / 2
            cropY = (image.height - cropHeight) / 2
        }

        func sample(x: Int, y: Int) -> UInt8 {
            let left = cropX + x * cropWidth / width
            let right = max(left + 1, cropX + (x + 1) * cropWidth / width)
            let top = cropY + y * cropHeight / height
            let bottom = max(top + 1, cropY + (y + 1) * cropHeight / height)
            var total = 0
            for row in top..<bottom {
                for column in left..<right {
                    total += Int(image.pixels[row * image.width + column])
                }
            }
            return UInt8(total / ((right - left) * (bottom - top)))
        }
    }

    nonisolated private static func insideRoundedRect(x: Int, y: Int, width: Int, height: Int, radius: Int) -> Bool {
        let px = Float(x) + 0.5
        let py = Float(y) + 0.5
        let r = Float(radius)
        let cx = min(max(px, r), Float(width) - r)
        let cy = min(max(py, r), Float(height) - r)
        return (px - cx) * (px - cx) + (py - cy) * (py - cy) <= r * r
    }

    nonisolated private static func nearestMultipleDistance(_ value: Float, _ spacing: Float) -> Float {
        abs(value - spacing * (value / spacing).rounded())
    }

    nonisolated private static func positiveModulo(_ value: Float, _ divisor: Float) -> Float {
        value - divisor * (value / divisor).rounded(.down)
    }

    nonisolated private static func truchetFlip(_ column: Int32, _ row: Int32) -> Bool {
        var hash = UInt32(bitPattern: column) &* 0x9E37_79B1 ^ UInt32(bitPattern: row) &* 0x85EB_CA77
        hash ^= hash >> 15
        hash = hash &* 0x2C1B_3C6D
        hash ^= hash >> 12
        return hash & 1 != 0
    }

    nonisolated static func patternCoverage(
        _ pattern: PaperGIFRemoteButtonPattern,
        x: Float,
        y: Float,
        spacing: Float,
        lineWidth: Float
    ) -> Float {
        let halfLine = lineWidth / 2
        func unit(_ value: Float) -> Float { min(1, max(0, value)) }
        func line(_ distance: Float) -> Float { unit(halfLine + 0.5 - distance) }
        switch pattern {
        case .hexagons:
            let px = x / spacing
            let py = y / spacing
            let rowStep: Float = 1.7320508
            let ax = positiveModulo(px, 1) - 0.5
            let ay = positiveModulo(py, rowStep) - rowStep / 2
            let bx = positiveModulo(px - 0.5, 1) - 0.5
            let by = positiveModulo(py - rowStep / 2, rowStep) - rowStep / 2
            let useA = ax * ax + ay * ay < bx * bx + by * by
            let gx = abs(useA ? ax : bx)
            let gy = abs(useA ? ay : by)
            let hexDistance = max(gx * 0.5 + gy * 0.8660254, gx)
            return line(abs(0.5 - hexDistance) * spacing)
        case .triangles:
            let height = spacing * 0.8660254
            let d0 = nearestMultipleDistance(y, height)
            let d1 = nearestMultipleDistance(x * 0.8660254 + y * 0.5, height)
            let d2 = nearestMultipleDistance(x * 0.8660254 - y * 0.5, height)
            return line(min(d0, d1, d2))
        case .grid:
            return line(min(nearestMultipleDistance(x, spacing), nearestMultipleDistance(y, spacing)))
        case .dots:
            let dx = x - spacing * (x / spacing).rounded()
            let dy = y - spacing * (y / spacing).rounded()
            let radius = max(1, spacing * 0.15 + halfLine)
            return unit(radius + 0.5 - (dx * dx + dy * dy).squareRoot())
        case .diagonal:
            return line(nearestMultipleDistance((x + y) * 0.70710678, spacing))
        case .checker:
            let cx = positiveModulo(x, spacing)
            let cy = positiveModulo(y, spacing)
            let edge = min(cx, spacing - cx, cy, spacing - cy)
            let inside = (Int((x / spacing).rounded(.down)) + Int((y / spacing).rounded(.down))) & 1 != 0
            return unit(0.5 + (inside ? edge : -edge))
        case .waves:
            let amplitude = spacing * 0.25
            let wavenumber = Float.pi / spacing
            let offset = y - amplitude * sin(x * wavenumber)
            let slope = amplitude * wavenumber * cos(x * wavenumber)
            return line(nearestMultipleDistance(offset, spacing) / (1 + slope * slope).squareRoot())
        case .rings:
            return line(nearestMultipleDistance((x * x + y * y).squareRoot(), spacing))
        case .spiral:
            let radius = (x * x + y * y).squareRoot()
            let turn = atan2(y, x) * (0.15915494 * spacing)
            return line(nearestMultipleDistance(radius - turn, spacing))
        case .truchet:
            let column = Int32((x / spacing).rounded(.down))
            let row = Int32((y / spacing).rounded(.down))
            var lx = x - Float(column) * spacing
            let ly = y - Float(row) * spacing
            if truchetFlip(column, row) { lx = spacing - lx }
            let half = spacing / 2
            let first = abs((lx * lx + ly * ly).squareRoot() - half)
            let sx = spacing - lx
            let sy = spacing - ly
            let second = abs((sx * sx + sy * sy).squareRoot() - half)
            return line(min(first, second))
        }
    }
}
