import Foundation
import PaperDeviceKit

struct PaperGIFDescriptorReader {
    private var bytes = Data()
    private var isComplete = false
    private var pendingDescriptor: DeviceDescriptor?
    var nextOffset: UInt32 { UInt32(bytes.count) }

    static func offsetRequest(_ requestedOffset: UInt32) -> Data {
        var offset = requestedOffset.littleEndian
        return withUnsafeBytes(of: &offset) { Data($0) }
    }

    mutating func append(_ page: Data) throws -> DeviceDescriptor? {
        guard !isComplete, page.count <= 512, bytes.count + page.count <= 65_536 else {
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
        guard page.count < 512 else { return nil }
        let descriptor = try DeviceDescriptor.decode(bytes)
        if page.isEmpty {
            isComplete = true
            return descriptor
        }
        pendingDescriptor = descriptor
        return nil
    }
}
