import CoreGraphics
import Foundation

public struct DeviceImageUploadAcknowledgement: Decodable, Sendable {
    public let ok: Bool
    public let id: UUID
    public let index: Int?
}

public struct HTTPDeviceImageTransport: Sendable {
    private let address: String
    private let token: String
    private let request: @Sendable (URLRequest, Int) async throws -> (Data, Int)

    public init(address: String, token: String,
                request: @escaping @Sendable (URLRequest, Int) async throws -> (Data, Int) = {
                    try await DeviceHTTP.request($0, maximumBytes: $1, timeout: 20)
                }) {
        self.address = address
        self.token = token
        self.request = request
    }

    public func upload(_ data: Data, id: UUID, name: String, checksum: UInt32,
                       button: Bool = false) async throws -> DeviceImageUploadAcknowledgement {
        guard (10...329_738).contains(data.count) else { throw DeviceContractError.invalid("image upload size") }
        var upload = URLRequest(url: try DeviceHTTP.endpoint(address, path: "/images"))
        upload.httpMethod = "POST"
        upload.httpBody = data
        upload.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        upload.setValue("close", forHTTPHeaderField: "Connection")
        upload.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        upload.setValue(id.uuidString, forHTTPHeaderField: "X-Image-ID")
        upload.setValue(button ? "button" : "screen", forHTTPHeaderField: "X-Image-Kind")
        upload.setValue(String(format: "%08X", checksum), forHTTPHeaderField: "X-Image-CRC32")
        let title = name.unicodeScalars.filter { $0.isASCII && (32...126).contains($0.value) }
        upload.setValue(String(String.UnicodeScalarView(title.prefix(48))), forHTTPHeaderField: "X-Image-Name")
        let (response, status) = try await request(upload, 4096)
        guard status == 200 || status == 201 else {
            throw HTTPDeviceControlTransport.rejection(response, status: status)
        }
        let acknowledgement = try JSONDecoder().decode(DeviceImageUploadAcknowledgement.self, from: response)
        guard acknowledgement.ok, acknowledgement.id == id,
              button || acknowledgement.index.map({ (0...127).contains($0) }) == true else {
            throw DeviceContractError.invalid("image installation acknowledgement")
        }
        return acknowledgement
    }
}

public enum DeviceImageEncoder {
    public static func decode(_ data: Data) throws -> CGImage {
        let bytes = [UInt8](data)
        guard bytes.count >= 10, Array(bytes.prefix(6)) == [80, 73, 77, 71, 1, 0] else {
            throw DeviceContractError.invalid("image header")
        }
        let width = Int(bytes[6]) | Int(bytes[7]) << 8
        let height = Int(bytes[8]) | Int(bytes[9]) << 8
        guard (1...8192).contains(width), (1...8192).contains(height),
              width * height <= 16_777_216, bytes.count == 10 + width * height * 2,
              let context = CGContext(data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else {
            throw DeviceContractError.invalid("image dimensions or pixels")
        }
        for index in 0..<(width * height) {
            let pixel = UInt16(bytes[10 + index * 2]) | UInt16(bytes[11 + index * 2]) << 8
            pixels[index * 4] = UInt8((pixel >> 11) * 255 / 31)
            pixels[index * 4 + 1] = UInt8(((pixel >> 5) & 63) * 255 / 63)
            pixels[index * 4 + 2] = UInt8((pixel & 31) * 255 / 31)
            pixels[index * 4 + 3] = 255
        }
        guard let image = context.makeImage() else { throw DeviceContractError.invalid("image allocation failed") }
        return image
    }

    public static func crop(_ image: CGImage, normalizedRect: CGRect?) throws -> CGImage {
        guard let rect = normalizedRect else { return image }
        guard [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite),
              rect.width > 0, rect.height > 0 else { throw DeviceContractError.invalid("image crop") }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let pixels = CGRect(x: rect.minX * bounds.width, y: rect.minY * bounds.height,
                            width: rect.width * bounds.width, height: rect.height * bounds.height)
            .integral.intersection(bounds)
        guard !pixels.isEmpty, let cropped = image.cropping(to: pixels) else {
            throw DeviceContractError.invalid("image crop is outside the source")
        }
        return cropped
    }

    public static func encode(_ image: CGImage, for display: DeviceDisplay) throws -> (data: Data, preview: CGImage) {
        guard display.pixelFormat == "rgb565", (1...8192).contains(display.width),
              (1...8192).contains(display.height), display.width * display.height <= 16_777_216 else {
            throw DeviceContractError.unsupported("image dimensions or pixel format")
        }
        guard let context = CGContext(data: nil, width: display.width, height: display.height,
            bitsPerComponent: 8, bytesPerRow: display.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw DeviceContractError.invalid("image allocation failed")
        }
        let width = CGFloat(display.width), height = CGFloat(display.height)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let scale = min(width / CGFloat(image.width), height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: (width - size.width) / 2, y: (height - size.height) / 2,
                                      width: size.width, height: size.height))
        guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self), let preview = context.makeImage() else {
            throw DeviceContractError.invalid("image rendering failed")
        }
        var data = Data("PIMG".utf8)
        data.reserveCapacity(10 + display.width * display.height * 2)
        data.append(contentsOf: [1, 0, UInt8(display.width & 255), UInt8(display.width >> 8),
                                UInt8(display.height & 255), UInt8(display.height >> 8)])
        for index in 0..<(display.width * display.height) {
            let offset = index * 4
            let pixel = UInt16(pixels[offset] >> 3) << 11 | UInt16(pixels[offset + 1] >> 2) << 5 |
                UInt16(pixels[offset + 2] >> 3)
            data.append(UInt8(pixel & 255))
            data.append(UInt8(pixel >> 8))
        }
        return (data, preview)
    }
}