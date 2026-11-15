import CoreGraphics
import Foundation

/// Grayscale source images for button textures, in the M5Paper's PBGI format:
/// "PBGI", version 1, reserved, little-endian width and height, then 8-bit luminance rows.
enum PaperGIFButtonImageStore {
    struct Image: Sendable {
        let width: Int
        let height: Int
        let pixels: [UInt8]
        let colorPixels: [UInt8]?

        init(width: Int, height: Int, pixels: [UInt8], colorPixels: [UInt8]? = nil) {
            self.width = width
            self.height = height
            self.pixels = pixels
            self.colorPixels = colorPixels
        }
    }

    nonisolated static let maximumSide = 400
    /// Phone photos. Panel firmware only accepts versions 1 and 2 up to 540 px.
    nonisolated static let phoneMaximumSide = 2048
    nonisolated private static let headerBytes = 10

    nonisolated static func makeImageFile(from mediaData: Data) throws -> Data {
        let source = try PaperGIFEncoder.previewImage(from: mediaData)
        return try makeImageFile(from: source)
    }

    nonisolated static func makeImageFile(from source: CGImage, color: Bool = false) throws -> Data {
        let scale = min(1, Double(maximumSide) / Double(max(source.width, source.height)))
        let width = max(1, Int((Double(source.width) * scale).rounded()))
        let height = max(1, Int((Double(source.height) * scale).rounded()))
        if color {
            var rgba = [UInt8](repeating: 255, count: width * height * 4)
            let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                context.interpolationQuality = .high
                context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { throw PaperGIFError.imageRenderFailed }
            var output = Data("PBGI".utf8)
            output.append(contentsOf: [2, 0, UInt8(width & 255), UInt8(width >> 8), UInt8(height & 255), UInt8(height >> 8)])
            for pixel in stride(from: 0, to: rgba.count, by: 4) {
                let value = UInt16(rgba[pixel] >> 3) << 11 | UInt16(rgba[pixel + 1] >> 2) << 5 | UInt16(rgba[pixel + 2] >> 3)
                output.append(contentsOf: [UInt8(value & 255), UInt8(value >> 8)])
            }
            return output
        }
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

    /// 8-bit RGB, scaled down only when a side exceeds the phone screen. Not a panel file.
    nonisolated static func makePhoneImageFile(from source: CGImage) throws -> Data {
        let scale = min(1, Double(phoneMaximumSide) / Double(max(source.width, source.height)))
        let width = max(1, Int((Double(source.width) * scale).rounded()))
        let height = max(1, Int((Double(source.height) * scale).rounded()))
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .high
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw PaperGIFError.imageRenderFailed }
        var output = Data("PBGI".utf8)
        output.append(contentsOf: [3, 0, UInt8(width & 255), UInt8(width >> 8), UInt8(height & 255), UInt8(height >> 8)])
        output.reserveCapacity(headerBytes + width * height * 3)
        for pixel in stride(from: 0, to: rgba.count, by: 4) {
            output.append(contentsOf: [rgba[pixel], rgba[pixel + 1], rgba[pixel + 2]])
        }
        return output
    }

    nonisolated static func decode(_ data: Data) -> Image? {
        let bytes = [UInt8](data)
        guard bytes.count >= headerBytes,
              bytes[0..<4].elementsEqual("PBGI".utf8),
              (1...3).contains(bytes[4]), bytes[5] == 0 else { return nil }
        let width = Int(bytes[6]) | Int(bytes[7]) << 8
        let height = Int(bytes[8]) | Int(bytes[9]) << 8
        let components = bytes[4] == 1 ? 1 : bytes[4] == 2 ? 2 : 3
        let maxSide = bytes[4] == 3 ? phoneMaximumSide : 540
        guard width > 0, height > 0, width <= maxSide, height <= maxSide,
              bytes.count == headerBytes + width * height * components else { return nil }
        if bytes[4] == 3 {
            var gray: [UInt8] = []
            var rgb: [UInt8] = []
            rgb.reserveCapacity(width * height * 3)
            gray.reserveCapacity(width * height)
            for offset in stride(from: headerBytes, to: bytes.count, by: 3) {
                let red = Int(bytes[offset]), green = Int(bytes[offset + 1]), blue = Int(bytes[offset + 2])
                rgb.append(contentsOf: [bytes[offset], bytes[offset + 1], bytes[offset + 2]])
                gray.append(UInt8((red * 299 + green * 587 + blue * 114) / 1000))
            }
            return Image(width: width, height: height, pixels: gray, colorPixels: rgb)
        }
        if bytes[4] == 2 {
            var gray: [UInt8] = []
            var rgb: [UInt8] = []
            for offset in stride(from: headerBytes, to: bytes.count, by: 2) {
                let value = UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
                let red = Int(value >> 11) * 255 / 31
                let green = Int((value >> 5) & 63) * 255 / 63
                let blue = Int(value & 31) * 255 / 31
                rgb.append(contentsOf: [UInt8(red), UInt8(green), UInt8(blue)])
                gray.append(UInt8((red * 299 + green * 587 + blue * 114) / 1000))
            }
            return Image(width: width, height: height, pixels: gray, colorPixels: rgb)
        }
        return Image(width: width, height: height, pixels: Array(bytes[headerBytes...]))
    }

    nonisolated static func save(_ data: Data, id: UUID) throws {
        try data.write(to: try fileURL(for: id), options: .atomic)
    }

    nonisolated static func grayscaleFile(_ data: Data) -> Data? {
        guard let image = decode(data) else { return nil }
        var output = Data("PBGI".utf8)
        output.append(contentsOf: [1, 0, UInt8(image.width & 255), UInt8(image.width >> 8),
            UInt8(image.height & 255), UInt8(image.height >> 8)])
        output.append(contentsOf: image.pixels)
        return output
    }

    /// A panel-sized grayscale file. Phone color photos are converted only if a panel sync asks for them.
    nonisolated static func panelFile(_ data: Data) -> Data? {
        guard let image = decode(data) else { return nil }
        let version = data.count > 4 ? data[4] : 0
        if version != 3, image.width <= 540, image.height <= 540, data.count <= 329_738 { return data }
        let scale = min(1, 540 / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        var pixels = [UInt8](repeating: 255, count: width * height)
        for y in 0..<height {
            let sourceY = min(image.height - 1, y * image.height / height)
            for x in 0..<width {
                let sourceX = min(image.width - 1, x * image.width / width)
                pixels[y * width + x] = image.pixels[sourceY * image.width + sourceX]
            }
        }
        var output = Data("PBGI".utf8)
        output.append(contentsOf: [1, 0, UInt8(width & 255), UInt8(width >> 8), UInt8(height & 255), UInt8(height >> 8)])
        output.append(contentsOf: pixels)
        return output
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
        let backgroundHex: String?
        let foregroundHex: String?
        let imageTintHex: String?
    }

    @MainActor private static var cache: [CacheKey: CGImage] = [:]
    @MainActor private static var images: [UUID: PaperGIFButtonImageStore.Image] = [:]

    @MainActor static func image(
        texture: PaperGIFRemoteButtonTexture,
        background: PaperGIFRemoteButtonBackground,
        width: Int,
        height: Int,
        radius: Int,
        backgroundHex: String? = nil, foregroundHex: String? = nil, imageTintHex: String? = nil
    ) -> CGImage? {
        let key = CacheKey(
            texture: texture, background: background, width: width, height: height, radius: radius,
            backgroundHex: backgroundHex, foregroundHex: foregroundHex, imageTintHex: imageTintHex
        )
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
            fill: backgroundHex != nil || foregroundHex != nil || imageTintHex != nil ? 255 : background.idleFillLuminance,
            foreground: backgroundHex != nil || foregroundHex != nil || imageTintHex != nil ? 0 : background.idleForegroundLuminance,
            width: width,
            height: height,
            radius: radius,
            backgroundHex: backgroundHex, foregroundHex: foregroundHex, imageTintHex: imageTintHex,
            defaultFill: background.idleFillLuminance, defaultForeground: background.idleForegroundLuminance
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
        radius: Int,
        backgroundHex: String? = nil, foregroundHex: String? = nil, imageTintHex: String? = nil,
        defaultFill: Int = 255, defaultForeground: Int = 0
    ) -> CGImage? {
        let inkPercent = Float(100 - min(100, max(0, texture.fade)))
        func composite(_ ink: Float) -> Int {
            fill + Int((Float(foreground - fill) * ink * inkPercent / 100).rounded())
        }
        var levels = [UInt8](repeating: 15, count: width * height)
        if texture.kind == .image, texture.preserveColor, imageTintHex == nil,
           let source, let colorPixels = source.colorPixels {
            return preservedColorImage(source: source, colorPixels: colorPixels, fade: texture.fade,
                backgroundHex: backgroundHex, defaultFill: defaultFill, width: width, height: height, radius: radius)
        }
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
        if backgroundHex != nil || foregroundHex != nil || imageTintHex != nil || (texture.preserveColor && source?.colorPixels != nil) {
            let backgroundRGB = UInt32(backgroundHex ?? "", radix: 16) ?? UInt32(defaultFill) * 0x010101
            let foregroundRGB = UInt32(imageTintHex ?? foregroundHex ?? "", radix: 16) ?? UInt32(defaultForeground) * 0x010101
            let sampler = source.map { CoverSampler(image: $0, width: width, height: height) }
            var rgb = [UInt8](repeating: 255, count: width * height * 3)
            for row in 0..<height { for column in 0..<width {
                guard insideRoundedRect(x: column, y: row, width: width, height: height, radius: radius) else { continue }
                var color = foregroundRGB
                var amount = 255 - Int(gray[row * width + column])
                if texture.preserveColor, imageTintHex == nil, let sampler, let sourceRGB = source?.colorPixels {
                    let sourceColumn = sampler.cropX + column * sampler.cropWidth / width
                    let sourceRow = sampler.cropY + row * sampler.cropHeight / height
                    let offset = (sourceRow * sampler.image.width + sourceColumn) * 3
                    color = UInt32(sourceRGB[offset]) << 16 | UInt32(sourceRGB[offset + 1]) << 8 | UInt32(sourceRGB[offset + 2])
                    amount = (100 - texture.fade) * 255 / 100
                }
                for channel in 0..<3 {
                    let shift = (2 - channel) * 8
                    let backgroundChannel = Int((backgroundRGB >> shift) & 255)
                    let foregroundChannel = Int((color >> shift) & 255)
                    let blended = (backgroundChannel * (255 - amount) + foregroundChannel * amount + 127) / 255
                    rgb[(row * width + column) * 3 + channel] = UInt8(blended)
                }
            } }
            guard let provider = CGDataProvider(data: Data(rgb) as CFData) else { return nil }
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: width * 3,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: [], provider: provider, decode: nil,
                shouldInterpolate: false, intent: .defaultIntent)
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
            let box = sampleBox(x: x, y: y)
            var total = 0
            for row in box.top..<box.bottom {
                for column in box.left..<box.right {
                    total += Int(image.pixels[row * image.width + column])
                }
            }
            return UInt8(total / ((box.right - box.left) * (box.bottom - box.top)))
        }

        func sampleColor(x: Int, y: Int, colorPixels: [UInt8]) -> [Int] {
            let box = sampleBox(x: x, y: y)
            var red = 0, green = 0, blue = 0
            for row in box.top..<box.bottom {
                for column in box.left..<box.right {
                    let offset = (row * image.width + column) * 3
                    guard offset + 2 < colorPixels.count else { continue }
                    red += Int(colorPixels[offset])
                    green += Int(colorPixels[offset + 1])
                    blue += Int(colorPixels[offset + 2])
                }
            }
            let count = (box.right - box.left) * (box.bottom - box.top)
            return [red / count, green / count, blue / count]
        }

        private func sampleBox(x: Int, y: Int) -> (left: Int, right: Int, top: Int, bottom: Int) {
            let left = min(image.width - 1, cropX + x * cropWidth / width)
            let right = min(image.width, max(left + 1, cropX + (x + 1) * cropWidth / width))
            let top = min(image.height - 1, cropY + y * cropHeight / height)
            let bottom = min(image.height, max(top + 1, cropY + (y + 1) * cropHeight / height))
            return (left, right, top, bottom)
        }
    }

    nonisolated private static func preservedColorImage(
        source: PaperGIFButtonImageStore.Image,
        colorPixels: [UInt8],
        fade: Int,
        backgroundHex: String?,
        defaultFill: Int,
        width: Int,
        height: Int,
        radius: Int
    ) -> CGImage? {
        guard colorPixels.count >= source.width * source.height * 3 else { return nil }
        let sampler = CoverSampler(image: source, width: width, height: height)
        let amount = (100 - min(100, max(0, fade))) * 255 / 100
        let backgroundRGB = UInt32(backgroundHex ?? "", radix: 16) ?? UInt32(defaultFill) * 0x010101
        var rgb = [UInt8](repeating: 255, count: width * height * 3)
        for row in 0..<height {
            for column in 0..<width {
                guard insideRoundedRect(x: column, y: row, width: width, height: height, radius: radius) else { continue }
                let sample = sampler.sampleColor(x: column, y: row, colorPixels: colorPixels)
                for channel in 0..<3 {
                    let shift = (2 - channel) * 8
                    let backgroundChannel = Int((backgroundRGB >> shift) & 255)
                    let blended = (backgroundChannel * (255 - amount) + sample[channel] * amount + 127) / 255
                    rgb[(row * width + column) * 3 + channel] = UInt8(clamping: blended)
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(rgb) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: width * 3,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: [], provider: provider, decode: nil,
            shouldInterpolate: true, intent: .defaultIntent)
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
