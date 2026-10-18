import SwiftUI

/// Wi-Fi setup for native boards: the device scans, the user picks a network and types only its password.
struct PaperGIFDeviceWiFiSetupSection: View {
    @ObservedObject var bluetooth: PaperGIFBluetoothManager
    @Binding var profile: PaperGIFRemoteProfile
    let onSaveProfile: () -> Void

    @State private var chosenNetwork: PaperGIFBluetoothManager.WiFiNetwork?
    @State private var password = ""
    @State private var askingPassword = false
    @State private var askingOtherNetwork = false
    @State private var otherSSID = ""

    var body: some View {
        Section {
            statusRow
            if bluetooth.canSetUpDeviceWiFi {
                ForEach(bluetooth.nearbyWiFiNetworks) { network in
                    Button { choose(network) } label: { networkRow(network) }
                        .disabled(bluetooth.isJoiningDeviceWiFi)
                }
                if bluetooth.isScanningWiFiNetworks {
                    HStack {
                        ProgressView()
                        Text("Device is scanning for networks…").foregroundStyle(.secondary)
                    }
                } else if bluetooth.nearbyWiFiNetworks.isEmpty, bluetooth.wifiScanError == nil {
                    Text("No 2.4 GHz networks found.").foregroundStyle(.secondary)
                }
                Button("Other Network…") {
                    otherSSID = ""
                    password = ""
                    askingOtherNetwork = true
                }
                .disabled(bluetooth.isJoiningDeviceWiFi)
                if let error = bluetooth.wifiScanError {
                    Text(error).font(.footnote).foregroundStyle(.orange)
                }
            } else {
                Text("Connect to this device over Bluetooth (select it above or under Nearby Bluetooth Devices) to choose its Wi-Fi network.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("Wi-Fi")
                Spacer()
                Button {
                    bluetooth.scanForWiFiNetworks()
                } label: {
                    Label("Scan", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
                }
                .disabled(!bluetooth.canSetUpDeviceWiFi || bluetooth.isScanningWiFiNetworks)
            }
        } footer: {
            Text("The device scans with its own radio, so only networks it can reach are listed. Computers on the same network discover it automatically; until then it uses Bluetooth.")
        }
        .onAppear(perform: scanIfNeeded)
        .onChange(of: bluetooth.canSetUpDeviceWiFi) { _, _ in scanIfNeeded() }
        .alert("Join “\(chosenNetwork?.ssid ?? "")”", isPresented: $askingPassword) {
            SecureField("Password", text: $password)
            Button("Join") { join(ssid: chosenNetwork?.ssid ?? "", password: password) }
                .disabled(password.utf8.count < 8)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter the Wi-Fi password. The device saves it and reconnects automatically.")
        }
        .alert("Other Network", isPresented: $askingOtherNetwork) {
            TextField("Network name", text: $otherSSID)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField("Password (blank if open)", text: $password)
            Button("Join") { join(ssid: otherSSID, password: password) }
                .disabled(otherSSID.isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("For hidden networks. The device only supports 2.4 GHz Wi-Fi.")
        }
    }

    @ViewBuilder private var statusRow: some View {
        if let status = bluetooth.deviceWiFiStatus {
            switch status.state {
            case .notConfigured:
                Label("Not connected to Wi-Fi. Choose a network below.", systemImage: "wifi.slash")
            case .connecting:
                HStack {
                    ProgressView()
                    Text("Joining \(status.ssid)…")
                }
            case .connected(let ipAddress):
                Label {
                    VStack(alignment: .leading) {
                        Text("Connected to \(status.ssid)")
                        Text(ipAddress).font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "wifi").foregroundStyle(.green)
                }
            case .failed(let message):
                Label {
                    VStack(alignment: .leading) {
                        Text(status.ssid.isEmpty ? "Wi-Fi failed" : "Couldn't join \(status.ssid)")
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
        }
    }

    private func networkRow(_ network: PaperGIFBluetoothManager.WiFiNetwork) -> some View {
        HStack {
            Text(network.ssid).foregroundStyle(.primary)
            Spacer()
            if case .connected = bluetooth.deviceWiFiStatus?.state, bluetooth.deviceWiFiStatus?.ssid == network.ssid {
                Image(systemName: "checkmark").foregroundStyle(.tint)
            }
            if network.isSecure { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary) }
            Image(systemName: "wifi", variableValue: signal(network.rssi)).foregroundStyle(.secondary)
        }
    }

    private func signal(_ rssi: Int) -> Double {
        min(1, max(0.1, Double(rssi + 90) / 40))
    }

    private func choose(_ network: PaperGIFBluetoothManager.WiFiNetwork) {
        chosenNetwork = network
        password = ""
        if network.isSecure { askingPassword = true } else { join(ssid: network.ssid, password: "") }
    }

    private func scanIfNeeded() {
        guard bluetooth.canSetUpDeviceWiFi, !bluetooth.isScanningWiFiNetworks,
              bluetooth.nearbyWiFiNetworks.isEmpty else { return }
        bluetooth.scanForWiFiNetworks()
    }

    private func join(ssid: String, password: String) {
        let ssid = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ssid.isEmpty else { return }
        bluetooth.joinDeviceWiFi(ssid: ssid, password: password, profile: profile)
        // Keep the phone's copy of the profile in step so a later sync doesn't revert the network.
        profile.wifiSSID = ssid
        profile.wifiPassword = password
        onSaveProfile()
    }
}
