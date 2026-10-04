import Combine
import Foundation

/// Apple Home power accessories shared by the paired iPhone; macOS apps outside Catalyst can't read HomeKit.
@MainActor
final class HomeAccessoryCatalog: ObservableObject {
    struct Accessory: Codable, Equatable, Identifiable, Sendable {
        let homeName: String
        let accessoryName: String
        let serviceName: String
        let accessoryID: String
        let serviceID: String

        var id: String { "\(accessoryID):\(serviceID)" }
        var displayName: String {
            let name = serviceName == accessoryName ? accessoryName : "\(accessoryName) · \(serviceName)"
            return "\(homeName) · \(name)"
        }
    }

    struct SharePayload: Codable, Sendable {
        let accessories: [Accessory]
    }

    static let shared = HomeAccessoryCatalog()
    nonisolated static let maximumAccessories = 128
    nonisolated private static let maximumTextLength = 128

    @Published private(set) var accessories: [Accessory] = []
    @Published private(set) var updatedAt: Date?

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("paperGIF Mac/home-accessories.json")
        if let data = try? Data(contentsOf: self.fileURL),
           let saved = try? JSONDecoder().decode(SharePayload.self, from: data) {
            accessories = saved.accessories
            updatedAt = (try? self.fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
    }

    /// Returns nil when the shared list is malformed or oversized.
    nonisolated static func validated(_ data: Data) -> [Accessory]? {
        guard let payload = try? JSONDecoder().decode(SharePayload.self, from: data),
              payload.accessories.count <= maximumAccessories else { return nil }
        for accessory in payload.accessories {
            let names = [accessory.homeName, accessory.accessoryName, accessory.serviceName]
            guard names.allSatisfy({ $0.count <= maximumTextLength }),
                  UUID(uuidString: accessory.accessoryID) != nil,
                  UUID(uuidString: accessory.serviceID) != nil else { return nil }
        }
        return payload.accessories
    }

    func replace(with accessories: [Accessory]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(SharePayload(accessories: accessories)).write(to: fileURL, options: .atomic)
        self.accessories = accessories
        updatedAt = Date()
    }
}
