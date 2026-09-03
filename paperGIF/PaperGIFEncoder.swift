import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct PaperGIFPlaybackConfiguration: Equatable, Sendable {
    nonisolated static let balanced = PaperGIFPlaybackConfiguration(
        scanRateHz: 60,
        transitionScans: 1,
        cleanRefreshInterval: 120,
        adaptiveCleaning: true
    )

    let scanRateHz: UInt16
    let transitionScans: UInt8
    let cleanRefreshInterval: UInt16
    let adaptiveCleaning: Bool

    nonisolated init(
        scanRateHz: UInt16,
        transitionScans: UInt8,
        cleanRefreshInterval: UInt16,
        adaptiveCleaning: Bool
    ) {
        self.scanRateHz = scanRateHz
        self.transitionScans = transitionScans
        self.cleanRefreshInterval = cleanRefreshInterval
        self.adaptiveCleaning = adaptiveCleaning
    }
}

enum PaperGIFError: LocalizedError {
    case invalidMedia
    case invalidPackage
    case noFrames
    case tooManyFrames(Int)
    case imageRenderFailed

    var errorDescription: String? {
        switch self {
        case .invalidMedia:
            "That file could not be decoded as an image or GIF."
        case .invalidPackage:
            "The saved paperGIF package is invalid."
        case .noFrames:
            "The selected file does not contain any images."
        case .tooManyFrames(let count):
            "The converted animation has \(count) frames. Choose a slower frame rate."
        case .imageRenderFailed:
            "An image frame could not be rendered."
        }
    }
}

struct PaperGIFAnimation: Sendable {
    nonisolated static let width = 540
    nonisolated static let height = 960
    nonisolated static let bytesPerRow = (width + 7) / 8
    nonisolated static let bytesPerFrame = bytesPerRow * height
    nonisolated static let grayscaleBytesPerRow = (width + 1) / 2
    nonisolated static let grayscaleBytesPerFrame = grayscaleBytesPerRow * height
    nonisolated static let legacyBytesPerFrame = width * height / 8

    let frames: [Data]
    let durations: [UInt16]
    let playbackConfiguration: PaperGIFPlaybackConfiguration

    nonisolated init(
        frames: [Data],
        durations: [UInt16],
        playbackConfiguration: PaperGIFPlaybackConfiguration
    ) {
        self.frames = frames
        self.durations = durations
        self.playbackConfiguration = playbackConfiguration
    }

    nonisolated init(encoded data: Data) throws {
        guard data.count >= 22,
              data.prefix(4) == Data("PGIF".utf8),
              let version = data.littleEndianValue(at: 4, as: UInt16.self),
              data.littleEndianValue(at: 6, as: UInt16.self) == UInt16(Self.width),
              data.littleEndianValue(at: 8, as: UInt16.self) == UInt16(Self.height),
              let frameCountValue = data.littleEndianValue(at: 10, as: UInt16.self),
              frameCountValue > 0,
              let encodedBytesPerFrame = data.littleEndianValue(at: 12, as: UInt32.self),
              let scanRateHz = data.littleEndianValue(at: 16, as: UInt16.self),
              let cleanRefreshInterval = data.littleEndianValue(at: 20, as: UInt16.self) else {
            throw PaperGIFError.invalidPackage
        }

        let frameSize: Int
        switch (version, encodedBytesPerFrame) {
        case (4, UInt32(Self.grayscaleBytesPerFrame)):
            frameSize = Self.grayscaleBytesPerFrame
        case (3, UInt32(Self.bytesPerFrame)):
            frameSize = Self.bytesPerFrame
        case (2, UInt32(Self.legacyBytesPerFrame)):
            frameSize = Self.legacyBytesPerFrame
        default:
            throw PaperGIFError.invalidPackage
        }
        let frameCount = Int(frameCountValue)
        let framesOffset = 22 + frameCount * MemoryLayout<UInt16>.size
        let expectedSize = framesOffset + frameCount * frameSize
        guard data.count == expectedSize,
              scanRateHz > 0,
              data[18] > 0,
              data[18] <= 9,
              data[19] <= 1,
              cleanRefreshInterval > 0 else {
            throw PaperGIFError.invalidPackage
        }

        var durations: [UInt16] = []
        var frames: [Data] = []
        durations.reserveCapacity(frameCount)
        frames.reserveCapacity(frameCount)
        for index in 0..<frameCount {
            guard let duration = data.littleEndianValue(
                at: 22 + index * MemoryLayout<UInt16>.size,
                as: UInt16.self
            ), duration > 0 else {
                throw PaperGIFError.invalidPackage
            }
            durations.append(duration)

            let frameStart = framesOffset + index * frameSize
            let frame = Data(data[frameStart..<(frameStart + frameSize)])
            frames.append(version == 2 ? Self.rowPaddedFrame(fromLegacy: frame) : frame)
        }

        self.frames = frames
        self.durations = durations
        playbackConfiguration = PaperGIFPlaybackConfiguration(
            scanRateHz: scanRateHz,
            transitionScans: data[18],
            cleanRefreshInterval: cleanRefreshInterval,
            adaptiveCleaning: data[19] == 1
        )
    }

    nonisolated var duration: TimeInterval {
        Double(durations.reduce(0) { $0 + UInt64($1) }) / 1_000
    }

    nonisolated var encoded: Data {
        let usesGrayscale = frames.first?.count == Self.grayscaleBytesPerFrame
        var output = Data("PGIF".utf8)
        output.appendLittleEndian(UInt16(usesGrayscale ? 4 : 3))
        output.appendLittleEndian(UInt16(Self.width))
        output.appendLittleEndian(UInt16(Self.height))
        output.appendLittleEndian(UInt16(frames.count))
        output.appendLittleEndian(UInt32(usesGrayscale ? Self.grayscaleBytesPerFrame : Self.bytesPerFrame))
        output.appendLittleEndian(playbackConfiguration.scanRateHz)
        output.append(playbackConfiguration.transitionScans)
        output.append(playbackConfiguration.adaptiveCleaning ? 1 : 0)
        output.appendLittleEndian(playbackConfiguration.cleanRefreshInterval)

        for duration in durations {
            output.appendLittleEndian(duration)
        }
        for frame in frames {
            output.append(frame)
        }
        return output
    }

    nonisolated private static func rowPaddedFrame(fromLegacy frame: Data) -> Data {
        var output = Data(repeating: 0, count: bytesPerFrame)
        for row in 0..<height {
            for column in 0..<width {
                let sourceBit = row * width + column
                guard frame[sourceBit / 8] & (0x80 >> (sourceBit % 8)) != 0 else { continue }
                let destinationBit = row * bytesPerRow * 8 + column
                output[destinationBit / 8] |= 0x80 >> (destinationBit % 8)
            }
        }
        return output
    }
}

struct PaperGIFFrameSample: Equatable, Sendable {
    let sourceIndex: Int
    let durationMilliseconds: UInt16
}

enum PaperGIFEncoder {
    nonisolated static func monochromePreview(
        image: CGImage,
        monochromeMode: PaperGIFMonochromeMode,
        threshold: UInt8,
        monochromeLevels: Int,
        halftoneDotSpacing: Int,
        halftoneAngle: Int,
        halftoneDotGain: Int,
        cropRect: CGRect?,
        rotationQuarterTurns: Int
    ) throws -> CGImage {
        let rotated = try rotatedImage(image, quarterTurns: rotationQuarterTurns)
        let frame = try packedFrame(
            image: rotated,
            monochromeMode: monochromeMode,
            threshold: threshold,
            monochromeLevels: monochromeLevels,
            halftoneDotSpacing: halftoneDotSpacing,
            halftoneAngle: halftoneAngle,
            halftoneDotGain: halftoneDotGain,
            cropRect: cropRect
        )
        return try previewImage(fromPackedFrame: frame)
    }

    nonisolated static func previewImage(fromPackedFrame frame: Data) throws -> CGImage {
        let grayscaleFrame: Data
        if frame.count == PaperGIFAnimation.bytesPerFrame {
            var expanded = Data(repeating: 255, count: PaperGIFAnimation.width * PaperGIFAnimation.height)
            for row in 0..<PaperGIFAnimation.height {
                for column in 0..<PaperGIFAnimation.width {
                    let sourceByte = frame[row * PaperGIFAnimation.bytesPerRow + column / 8]
                    if sourceByte & (0x80 >> (column % 8)) != 0 {
                        expanded[row * PaperGIFAnimation.width + column] = 0
                    }
                }
            }
            grayscaleFrame = expanded
        } else if frame.count == PaperGIFAnimation.grayscaleBytesPerFrame {
            var expanded = Data(repeating: 0, count: PaperGIFAnimation.width * PaperGIFAnimation.height)
            for pixelIndex in 0..<expanded.count {
                let byte = frame[pixelIndex / 2]
                let level = pixelIndex.isMultiple(of: 2) ? byte >> 4 : byte & 0x0F
                expanded[pixelIndex] = level * 17
            }
            grayscaleFrame = expanded
        } else {
            throw PaperGIFError.invalidPackage
        }
        guard let provider = CGDataProvider(data: grayscaleFrame as CFData),
              let image = CGImage(
                width: PaperGIFAnimation.width,
                height: PaperGIFAnimation.height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 8,
                  bytesPerRow: PaperGIFAnimation.width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: [],
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw PaperGIFError.imageRenderFailed
        }
        return image
    }

    nonisolated static func encode(
        mediaData: Data,
        monochromeMode: PaperGIFMonochromeMode,
        threshold: UInt8,
        monochromeLevels: Int,
        halftoneDotSpacing: Int,
        halftoneAngle: Int,
        halftoneDotGain: Int,
        maximumFramesPerSecond: Double,
        cropRect: CGRect? = nil,
        rotationQuarterTurns: Int = 0,
        playbackConfiguration: PaperGIFPlaybackConfiguration = .balanced,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> PaperGIFAnimation {
        let source = try imageSource(from: mediaData)

        let sourceFrameCount = CGImageSourceGetCount(source)
        guard sourceFrameCount > 0 else { throw PaperGIFError.noFrames }

        let samples = frameSamples(
            sourceDurations: (0..<sourceFrameCount).map { frameDuration(source: source, index: $0) },
            maximumFramesPerSecond: maximumFramesPerSecond
        )
        guard samples.count <= Int(UInt16.max) else {
            throw PaperGIFError.tooManyFrames(samples.count)
        }

        var frames: [Data] = []
        var durations: [UInt16] = []
        frames.reserveCapacity(samples.count)
        durations.reserveCapacity(samples.count)

        for (sampleIndex, sample) in samples.enumerated() {
            let frame = try autoreleasepool {
                let decodedImage = try decodedImage(source: source, index: sample.sourceIndex)
                let image = try rotatedImage(decodedImage, quarterTurns: rotationQuarterTurns)
                return try packedFrame(
                    image: image,
                    monochromeMode: monochromeMode,
                    threshold: threshold,
                    monochromeLevels: monochromeLevels,
                    halftoneDotSpacing: halftoneDotSpacing,
                    halftoneAngle: halftoneAngle,
                    halftoneDotGain: halftoneDotGain,
                    cropRect: cropRect
                )
            }
            frames.append(frame)
            durations.append(sample.durationMilliseconds)
            progress?(Double(sampleIndex + 1) / Double(samples.count))
        }

        return PaperGIFAnimation(
            frames: frames,
            durations: durations,
            playbackConfiguration: playbackConfiguration
        )
    }

    nonisolated static func frameSamples(
        sourceDurations: [TimeInterval],
        maximumFramesPerSecond: Double
    ) -> [PaperGIFFrameSample] {
        let minimumDuration = 1 / max(1, maximumFramesPerSecond)
        var samples: [PaperGIFFrameSample] = []
        var groupedDuration = 0.0
        var totalDuration = 0.0
        var emittedMilliseconds = 0

        for (index, sourceDuration) in sourceDurations.enumerated() {
            let duration = max(0.01, sourceDuration)
            groupedDuration += duration
            totalDuration += duration
            guard groupedDuration >= minimumDuration || index == sourceDurations.count - 1 else {
                continue
            }

            let roundedTotal = max(emittedMilliseconds + 1, Int((totalDuration * 1_000).rounded()))
            var remainingMilliseconds = roundedTotal - emittedMilliseconds
            while remainingMilliseconds > 0 {
                let sampleDuration = min(remainingMilliseconds, Int(UInt16.max))
                samples.append(PaperGIFFrameSample(
                    sourceIndex: index,
                    durationMilliseconds: UInt16(sampleDuration)
                ))
                remainingMilliseconds -= sampleDuration
            }
            emittedMilliseconds = roundedTotal
            groupedDuration = 0
        }
        return samples
    }

    nonisolated static func previewImage(from mediaData: Data) throws -> CGImage {
        try decodedImage(source: imageSource(from: mediaData), index: 0)
    }

    nonisolated static func rotatedImage(_ image: CGImage, quarterTurns: Int) throws -> CGImage {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else { return image }

        let swapsDimensions = turns % 2 == 1
        let width = swapsDimensions ? image.height : image.width
        let height = swapsDimensions ? image.width : image.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw PaperGIFError.imageRenderFailed
        }

        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        context.rotate(by: -CGFloat(turns) * .pi / 2)
        context.draw(
            image,
            in: CGRect(
                x: -CGFloat(image.width) / 2,
                y: -CGFloat(image.height) / 2,
                width: CGFloat(image.width),
                height: CGFloat(image.height)
            )
        )
        guard let rotatedImage = context.makeImage() else {
            throw PaperGIFError.imageRenderFailed
        }
        return rotatedImage
    }

    nonisolated static func packLuminance(_ pixels: [UInt8], threshold: UInt8, width: Int? = nil) -> Data {
        let rowWidth = width ?? pixels.count
        let bytesPerRow = (rowWidth + 7) / 8
        let rowCount = (pixels.count + rowWidth - 1) / rowWidth
        var packed = Data(repeating: 0, count: bytesPerRow * rowCount)
        for (index, luminance) in pixels.enumerated() where luminance < threshold {
            let row = index / rowWidth
            let column = index % rowWidth
            packed[row * bytesPerRow + column / 8] |= UInt8(0x80 >> (column % 8))
        }
        return packed
    }

    nonisolated static func packHalftoneLuminance(
        _ pixels: [UInt8],
        dotSpacing: Int,
        angleDegrees: Int,
        dotGain: Int,
        width: Int
    ) -> Data {
        let spacing = Double(max(2, dotSpacing))
        let angle = Double(angleDegrees) * .pi / 180
        let cosine = cos(angle)
        let sine = sin(angle)
        let bytesPerRow = (width + 7) / 8
        let rowCount = (pixels.count + width - 1) / width
        var packed = Data(repeating: 0, count: bytesPerRow * rowCount)

        for (index, luminance) in pixels.enumerated() {
            let coverage = min(1, max(0,
                1 - Double(luminance) / 255 + Double(dotGain) / 100
            ))
            guard coverage > 0 else { continue }
            let row = index / width
            let column = index % width
            if coverage < 1 {
                let x = Double(column) + 0.5
                let y = Double(row) + 0.5
                let screenX = x * cosine + y * sine
                let screenY = -x * sine + y * cosine
                let localX = screenX - floor(screenX / spacing) * spacing - spacing / 2
                let localY = screenY - floor(screenY / spacing) * spacing - spacing / 2
                let radialRank = min(1, .pi * (localX * localX + localY * localY) / (spacing * spacing))
                guard radialRank < coverage else { continue }
            }
            packed[row * bytesPerRow + column / 8] |= UInt8(0x80 >> (column % 8))
        }
        return packed
    }

    nonisolated static func packGrayscaleLuminance(
        _ pixels: [UInt8],
        levels: Int,
        threshold: UInt8,
        halftoneDotSpacing: Int? = nil,
        halftoneAngle: Int = 45,
        halftoneDotGain: Int = 0,
        width: Int
    ) -> Data {
        let levelCount = min(16, max(2, levels))
        let bytesPerRow = (width + 1) / 2
        let rowCount = (pixels.count + width - 1) / width
        let spacing = Double(max(2, halftoneDotSpacing ?? 2))
        let angle = Double(halftoneAngle) * .pi / 180
        let cosine = cos(angle)
        let sine = sin(angle)
        var packed = Data(repeating: 0, count: bytesPerRow * rowCount)

        for (index, luminance) in pixels.enumerated() {
            let adjusted = min(255, max(0, Int(luminance) + 128 - Int(threshold)))
            let scaledLevel = Double(adjusted) / 255 * Double(levelCount - 1)
            let quantizedLevel: Int
            if halftoneDotSpacing != nil {
                let darkerLevel = Int(floor(scaledLevel))
                let lighterLevel = min(levelCount - 1, darkerLevel + 1)
                let lighterFraction = scaledLevel - Double(darkerLevel)
                let darkCoverage = min(1, max(0, 1 - lighterFraction + Double(halftoneDotGain) / 100))
                let row = index / width
                let column = index % width
                let x = Double(column) + 0.5
                let y = Double(row) + 0.5
                let screenX = x * cosine + y * sine
                let screenY = -x * sine + y * cosine
                let localX = screenX - floor(screenX / spacing) * spacing - spacing / 2
                let localY = screenY - floor(screenY / spacing) * spacing - spacing / 2
                let radialRank = min(1, .pi * (localX * localX + localY * localY) / (spacing * spacing))
                quantizedLevel = radialRank < darkCoverage ? darkerLevel : lighterLevel
            } else {
                quantizedLevel = Int(scaledLevel.rounded())
            }

            let panelLevel = UInt8((Double(quantizedLevel) / Double(levelCount - 1) * 15).rounded())
            let row = index / width
            let column = index % width
            let byteIndex = row * bytesPerRow + column / 2
            if column.isMultiple(of: 2) {
                packed[byteIndex] |= panelLevel << 4
            } else {
                packed[byteIndex] |= panelLevel
            }
        }
        return packed
    }

    nonisolated static func packedFrame(
        image: CGImage,
        monochromeMode: PaperGIFMonochromeMode = .threshold,
        threshold: UInt8,
        monochromeLevels: Int = 16,
        halftoneDotSpacing: Int = 8,
        halftoneAngle: Int = 45,
        halftoneDotGain: Int = 0,
        cropRect: CGRect? = nil
    ) throws -> Data {
        let width = PaperGIFAnimation.width
        let height = PaperGIFAnimation.height
        var luminance = [UInt8](repeating: 255, count: width * height)
        guard let context = CGContext(
            data: &luminance,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            throw PaperGIFError.imageRenderFailed
        }

        context.interpolationQuality = .high
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let sourceRect: CGRect
        if let cropRect {
            sourceRect = CGRect(
                x: cropRect.minX * CGFloat(image.width),
                y: cropRect.minY * CGFloat(image.height),
                width: cropRect.width * CGFloat(image.width),
                height: cropRect.height * CGFloat(image.height)
            ).intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard sourceRect.width > 0, sourceRect.height > 0 else {
                throw PaperGIFError.imageRenderFailed
            }
        } else {
            sourceRect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        }

        let scale = min(CGFloat(width) / sourceRect.width, CGFloat(height) / sourceRect.height)
        let drawSize = CGSize(
            width: CGFloat(image.width) * scale,
            height: CGFloat(image.height) * scale
        )
        let drawRect = CGRect(
            x: (CGFloat(width) - sourceRect.width * scale) / 2 - sourceRect.minX * scale,
            y: (CGFloat(height) - sourceRect.height * scale) / 2 - sourceRect.minY * scale,
            width: drawSize.width,
            height: drawSize.height
        )
        context.draw(image, in: drawRect)
        switch monochromeMode {
        case .threshold:
            return packLuminance(luminance, threshold: threshold, width: width)
        case .monochrome:
            guard monochromeLevels > 0 else {
                return packLuminance(luminance, threshold: threshold, width: width)
            }
            return packGrayscaleLuminance(
                luminance,
                levels: monochromeLevels,
                threshold: threshold,
                width: width
            )
        case .halftone:
            return packHalftoneLuminance(
                luminance,
                dotSpacing: halftoneDotSpacing,
                angleDegrees: halftoneAngle,
                dotGain: halftoneDotGain,
                width: width
            )
        case .combined:
            guard monochromeLevels > 0 else {
                let shiftedLuminance = luminance.map {
                    UInt8(clamping: Int($0) + 128 - Int(threshold))
                }
                return packHalftoneLuminance(
                    shiftedLuminance,
                    dotSpacing: halftoneDotSpacing,
                    angleDegrees: halftoneAngle,
                    dotGain: halftoneDotGain,
                    width: width
                )
            }
            return packGrayscaleLuminance(
                luminance,
                levels: monochromeLevels,
                threshold: threshold,
                halftoneDotSpacing: halftoneDotSpacing,
                halftoneAngle: halftoneAngle,
                halftoneDotGain: halftoneDotGain,
                width: width
            )
        }
    }

    nonisolated private static func imageSource(from mediaData: Data) throws -> CGImageSource {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(mediaData as CFData, options),
              let typeIdentifier = CGImageSourceGetType(source),
              UTType(typeIdentifier as String)?.conforms(to: .image) == true else {
            throw PaperGIFError.invalidMedia
        }
        return source
    }

    nonisolated private static func decodedImage(source: CGImageSource, index: Int) throws -> CGImage {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let pixelWidth = properties?[kCGImagePropertyPixelWidth] as? Int ?? PaperGIFAnimation.width
        let pixelHeight = properties?[kCGImagePropertyPixelHeight] as? Int ?? PaperGIFAnimation.height
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(pixelWidth, pixelHeight),
            kCGImageSourceShouldCacheImmediately: false,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
            throw PaperGIFError.imageRenderFailed
        }
        return image
    }

    nonisolated private static func frameDuration(source: CGImageSource, index: Int) -> TimeInterval {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] else {
            return 0.1
        }
        let unclamped = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double
        let clamped = gif[kCGImagePropertyGIFDelayTime] as? Double
        return max(0.01, unclamped ?? clamped ?? 0.1)
    }
}

private extension Data {
    nonisolated mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }

    nonisolated func littleEndianValue<T: FixedWidthInteger>(at offset: Int, as type: T.Type) -> T? {
        guard offset >= 0, offset + MemoryLayout<T>.size <= count else { return nil }
        return self[offset..<(offset + MemoryLayout<T>.size)].enumerated().reduce(0) { value, element in
            value | T(element.element) << T(element.offset * 8)
        }
    }
}