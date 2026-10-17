import Foundation

/// Reads the paged native descriptor from the BLE descriptor characteristic.
///
/// Write `offsetRequest(nextOffset)` then read a page, until `append` returns a descriptor.
/// The firmware holds an exclusive lease until the empty EOF page is read.
public struct DeviceBLEDescriptorReader: Sendable {
    public static let pageSize = 512
    public static let maximumBytes = 65_536

    private var bytes = Data()
    private var isComplete = false
    private var pendingDescriptor: DeviceDescriptor?

    public init() {}

    public var nextOffset: UInt32 { UInt32(bytes.count) }

    public static func offsetRequest(_ requestedOffset: UInt32) -> Data {
        var offset = requestedOffset.littleEndian
        return withUnsafeBytes(of: &offset) { Data($0) }
    }

    public mutating func append(_ page: Data) throws -> DeviceDescriptor? {
        guard !isComplete, page.count <= Self.pageSize, bytes.count + page.count <= Self.maximumBytes else {
            throw DeviceContractError.invalid("Bluetooth descriptor exceeds its paging or size limit")
        }
        if let pendingDescriptor {
            guard page.isEmpty else {
                throw DeviceContractError.invalid("Bluetooth descriptor lease must end with an empty EOF read")
            }
            isComplete = true
            return pendingDescriptor
        }
        bytes.append(page)
        guard page.count < Self.pageSize else { return nil }
        let descriptor = try DeviceDescriptor.decode(bytes)
        if page.isEmpty {
            isComplete = true
            return descriptor
        }
        pendingDescriptor = descriptor
        return nil
    }
}
