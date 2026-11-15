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
                action.type == .netHomeTemperature || action.type == .netHomeFan ||
                (action.type == .computerMedia && ["volume", "seek"].contains(action.text))
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
    static func profileFromDeviceRefresh(_ data: Data, descriptor: DeviceDescriptor,
        previousLocalProfile: Self, currentLocalProfile: Self) throws -> Self {
        guard previousLocalProfile == currentLocalProfile else {
            throw DeviceContractError.invalid("The local profile changed while loading. Load from the device again before syncing.")
        }
        let loaded = try JSONDecoder().decode(Self.self, from: data)
        _ = try loaded.negotiatedPayload(for: descriptor)
        return loaded
    }

    mutating func prepareBluetoothEnrollment(for descriptor: DeviceDescriptor, savedToken: String) -> Bool {
        guard descriptor.requiresProfileEnrollmentToken, deviceEnrollmentToken.isEmpty else { return false }
        macToken = savedToken.isEmpty ? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() : savedToken
        markUpdated()
        return true
    }

    mutating func prepareAMOLEDPageTiles(for descriptor: DeviceDescriptor) -> Bool {
        guard descriptor.boardID == "paperremote.waveshare-amoled-18-v2",
              pages.allSatisfy({ $0.controls.isEmpty }) else { return false }
        let candidates = hardwareBindings.indices.filter {
            hardwareBindings[$0].pageID == nil && ["press", "change"].contains(hardwareBindings[$0].event)
        }
        guard !candidates.isEmpty else { return false }
        var page = pages.first ?? PaperGIFRemotePage(name: "Main", controls: [])
        page.gridColumns = 2
        page.gridRows = 4
        for index in candidates {
            let binding = hardwareBindings[index]
            let adjusting = binding.mode != "action"
            let name = descriptor.inputs.first(where: { $0.id == binding.inputID })?.name ?? binding.inputID
            var action = binding.action
            let media = action.type == .computerMedia || action.type == .iPhoneMedia
            if adjusting && media { action.value = Int((Double(action.value) * 255 / 100).rounded()) }
            let title = adjusting ? (action.type == .wledBrightness ? "Brightness" : action.type == .netHomeTemperature ? "Temperature" : "Volume") : name
            let control = PaperGIFRemoteControl(title: title,
                symbol: adjusting ? "slider.horizontal.3" : "circle.fill", tintHex: "202020",
                kind: adjusting ? .slider : .button, gridWidth: adjusting ? 2 : 1, action: action)
            page.controls.append(control)
            hardwareBindings[index].pageID = page.id
            hardwareBindings[index].controlID = control.id
            hardwareBindings[index].action = action
        }
        if pages.isEmpty { pages.append(page) } else { pages[0] = page }
        version = 7
        return true
    }

    mutating func reconcileTileBindings() {
        hardwareBindings = hardwareBindings.compactMap { binding in
            guard let pageID = binding.pageID else { return binding }
            guard let page = pages.first(where: { $0.id == pageID }) else { return nil }
            guard let controlID = binding.controlID else { return binding }
            guard let control = page.controls.first(where: { $0.id == controlID }),
                  (binding.mode == "action" ? control.kind == .button : control.kind == .slider) else { return nil }
            var updated = binding
            updated.action = control.action
            return updated
        }
    }

    var deviceEnrollmentToken: String {
        !macToken.isEmpty ? macToken : computers.first(where: { !$0.token.isEmpty })?.token ?? ""
    }

    mutating func prepareWiFiConfiguration(for descriptor: DeviceDescriptor) throws {
        let ssid = wifiSSID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ssid.isEmpty, ssid.utf8.count <= 32 else {
            throw DeviceContractError.invalid("enter a Wi-Fi name between 1 and 32 bytes")
        }
        let passwordBytes = wifiPassword.utf8.count
        let hexKey = passwordBytes == 64 && wifiPassword.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
        guard wifiPassword.isEmpty || (8...63).contains(passwordBytes) || hexKey else {
            throw DeviceContractError.invalid("Wi-Fi passwords must be 8-63 bytes, a 64-digit hexadecimal key, or empty for an open network")
        }
        wifiSSID = ssid
        if descriptor.requiresProfileEnrollmentToken, deviceEnrollmentToken.isEmpty {
            macToken = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        }
        _ = try negotiatedPayload(for: descriptor)
        markUpdated()
    }

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
        let groups = Dictionary(grouping: hardwareBindings) {
            "\($0.pageID?.uuidString ?? "global"):\($0.inputID):\($0.event)"
        }
        for bindings in groups.values where bindings.count > 1 {
            guard bindings.count == 2,
                  bindings.allSatisfy({ $0.mode == "action" && $0.direction != nil }),
                  Set(bindings.compactMap(\.direction)) == Set(["negative", "positive"]) else {
                throw DeviceContractError.invalid("overlapping bindings for an input event")
            }
        }
        var resolved = self
        for index in resolved.hardwareBindings.indices {
            var binding = resolved.hardwareBindings[index]
            if let pageID = binding.pageID {
                guard descriptor.display != nil, let page = pages.first(where: { $0.id == pageID }) else {
                    throw DeviceContractError.invalid("hardware binding page is missing")
                }
                if let controlID = binding.controlID {
                    guard let control = page.controls.first(where: { $0.id == controlID }),
                          (binding.mode == "action" ? control.kind == .button : control.kind == .slider) else {
                        throw DeviceContractError.invalid("hardware binding tile is missing or has the wrong kind")
                    }
                    binding.action = control.action
                }
            } else if binding.controlID != nil {
                throw DeviceContractError.invalid("tile bindings require a page")
            }
            try binding.validate(for: descriptor)
            resolved.hardwareBindings[index] = binding
        }
        guard descriptor.display != nil || pages.allSatisfy({ $0.controls.isEmpty }) else {
            throw DeviceContractError.unsupported("screenless devices cannot receive touchscreen controls")
        }
        if !descriptor.isM5Paper,
           pages.flatMap(\.controls).contains(where: {
               $0.action.type == .iPhoneMedia || $0.action.type == .iPhoneHomePower
           }) {
            throw DeviceContractError.unsupported("phone-local screen actions require the M5Paper Bluetooth adapter")
        }
        guard descriptor.canUseLegacyMedia || descriptor.canUseColorImages || referencedButtonImageIDs.isEmpty else {
            throw DeviceContractError.unsupported("this device does not advertise button image support")
        }
        guard let payload = resolved.devicePayload(version: version),
              payload.count <= capabilities.maxProfileBytes else {
            throw DeviceContractError.invalid("profile exceeds the device's byte limit")
        }
        return payload
    }
}
