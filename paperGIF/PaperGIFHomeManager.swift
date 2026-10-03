import Combine
import HomeKit

struct PaperGIFHomePowerService: Identifiable, Equatable, Sendable {
    let homeName: String
    let accessoryName: String
    let serviceName: String
    let accessoryID: String
    let serviceID: String
    let isReachable: Bool

    var id: String { "\(accessoryID):\(serviceID)" }
    var displayName: String {
        serviceName == accessoryName ? accessoryName : "\(accessoryName) · \(serviceName)"
    }
}

@MainActor
final class PaperGIFHomeManager: NSObject, ObservableObject, HMHomeManagerDelegate {
    @Published private(set) var powerServices: [PaperGIFHomePowerService] = []
    @Published private(set) var authorizationStatus: HMHomeManagerAuthorizationStatus = []
    @Published private(set) var isRefreshing = true

    private var manager = HMHomeManager()

    override init() {
        super.init()
        manager.delegate = self
        authorizationStatus = manager.authorizationStatus
    }

    func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        authorizationStatus = manager.authorizationStatus
        refreshPowerServices()
        isRefreshing = false
    }

    func homeManager(
        _ manager: HMHomeManager,
        didUpdate status: HMHomeManagerAuthorizationStatus
    ) {
        authorizationStatus = status
        refreshPowerServices()
    }

    func refreshAccessories() {
        isRefreshing = true
        manager.delegate = nil
        manager = HMHomeManager()
        manager.delegate = self
        authorizationStatus = manager.authorizationStatus
    }

    func performPowerCommand(
        _ command: String,
        accessoryID: String,
        serviceID: String,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        guard let service = homeService(accessoryID: accessoryID, serviceID: serviceID),
              let characteristic = service.characteristics.first(where: {
                  $0.characteristicType == HMCharacteristicTypePowerState
              }) else {
            completion(PaperGIFHomeError.accessoryUnavailable)
            return
        }

        if command == "toggle" {
            characteristic.readValue { error in
                guard error == nil else {
                    completion(error)
                    return
                }
                let isOn = (characteristic.value as? NSNumber)?.boolValue ?? false
                characteristic.writeValue(!isOn, completionHandler: completion)
            }
        } else {
            characteristic.writeValue(command == "on", completionHandler: completion)
        }
    }

    private func refreshPowerServices() {
        guard authorizationStatus.contains(.authorized) else {
            powerServices = []
            return
        }
        var discoveredServices: [PaperGIFHomePowerService] = []
        for home in manager.homes {
            for accessory in home.accessories {
                for service in accessory.services {
                    guard service.characteristics.contains(where: {
                        $0.characteristicType == HMCharacteristicTypePowerState
                    }) else { continue }
                    discoveredServices.append(PaperGIFHomePowerService(
                        homeName: home.name,
                        accessoryName: accessory.name,
                        serviceName: service.name,
                        accessoryID: accessory.uniqueIdentifier.uuidString,
                        serviceID: service.uniqueIdentifier.uuidString,
                        isReachable: accessory.isReachable
                    ))
                }
            }
        }
        powerServices = discoveredServices.sorted {
            let left = "\($0.homeName) \($0.displayName)"
            let right = "\($1.homeName) \($1.displayName)"
            return left.localizedStandardCompare(right) == .orderedAscending
        }
    }

    private func homeService(accessoryID: String, serviceID: String) -> HMService? {
        manager.homes
            .flatMap(\.accessories)
            .first(where: { $0.uniqueIdentifier.uuidString == accessoryID })?
            .services
            .first(where: { $0.uniqueIdentifier.uuidString == serviceID })
    }
}

private enum PaperGIFHomeError: LocalizedError {
    case accessoryUnavailable

    var errorDescription: String? {
        "The selected Home accessory is unavailable."
    }
}