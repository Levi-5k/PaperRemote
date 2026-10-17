import Foundation
import PaperDeviceKit

extension PaperGIFHardwareBinding {
    func validate(for descriptor: DeviceDescriptor) throws {
        try DeviceHardwareBinding(
            inputID: inputID, event: event, mode: mode, action: true,
            minimum: minimum, maximum: maximum, step: step, direction: direction
        ).validate(for: descriptor)
        if let direction {
            guard ["negative", "positive"].contains(direction), event == "rotate", mode == "action" else {
                throw DeviceContractError.invalid("direction requires a rotation action")
            }
        }
        if mode != "action" {
            let valueAction = action.type == .wledBrightness ||
                action.type == .netHomeTemperature ||
                (action.type == .computerMedia && action.text == "volume")
            guard valueAction else {
                throw DeviceContractError.unsupported("this action cannot accept an adjusted value")
            }
            let bounds: ClosedRange<Double>
            switch action.type {
            case .wledBrightness: bounds = 0...255
            case .netHomeTemperature: bounds = -3276.8...3276.7
            default: bounds = 0...100
            }
            guard bounds.contains(minimum), bounds.contains(maximum) else {
                throw DeviceContractError.invalid("adjustment range exceeds this action's supported values")
            }
        }
        guard action.type != .iPhoneMedia, action.type != .iPhoneHomePower else {
            throw DeviceContractError.unsupported("phone-local actions require the M5Paper Bluetooth adapter")
        }
    }
}

extension PaperGIFRemoteProfile {
    func negotiatedPayload(for descriptor: DeviceDescriptor) throws -> Data {
        try descriptor.validate()
        let capabilities = descriptor.capabilities
        let version = capabilities.profileVersions.contains(7) ? 7 : 6
        guard capabilities.profileVersions.contains(version),
              hardwareBindings.isEmpty || version == 7 else {
            throw DeviceContractError.unsupported("hardware bindings require profile version 7")
        }
        guard pages.count <= capabilities.maxPages,
              pages.allSatisfy({
                  $0.controls.count <= capabilities.maxControls &&
                  (1...12).contains($0.gridColumns) && (1...16).contains($0.gridRows)
              }),
              hardwareBindings.count <= capabilities.maxControls else {
            throw DeviceContractError.invalid("profile exceeds this device's page or control capacity")
        }
        guard Set(hardwareBindings.map(\.id)).count == hardwareBindings.count else {
            throw DeviceContractError.invalid("duplicate hardware binding")
        }
        let groups = Dictionary(grouping: hardwareBindings) { "\($0.inputID):\($0.event)" }
        for bindings in groups.values where bindings.count > 1 {
            guard bindings.count == 2,
                  bindings.allSatisfy({ $0.mode == "action" && $0.direction != nil }),
                  Set(bindings.compactMap(\.direction)) == Set(["negative", "positive"]) else {
                throw DeviceContractError.invalid("overlapping bindings for an input event")
            }
        }
        for binding in hardwareBindings { try binding.validate(for: descriptor) }
        guard descriptor.display != nil || pages.allSatisfy({ $0.controls.isEmpty }) else {
            throw DeviceContractError.unsupported("screenless devices cannot receive touchscreen controls")
        }
        if !descriptor.isM5Paper,
           pages.flatMap(\.controls).contains(where: {
               $0.action.type == .iPhoneMedia || $0.action.type == .iPhoneHomePower
           }) {
            throw DeviceContractError.unsupported("phone-local screen actions require the M5Paper Bluetooth adapter")
        }
        guard descriptor.canUseLegacyMedia || referencedButtonImageIDs.isEmpty else {
            throw DeviceContractError.unsupported("button image encoding is only available for M5Paper")
        }
        guard let payload = devicePayload(version: version),
              payload.count <= capabilities.maxProfileBytes else {
            throw DeviceContractError.invalid("profile exceeds the device's byte limit")
        }
        return payload
    }
}
