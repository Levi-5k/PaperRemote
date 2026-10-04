import SwiftUI

/// Versions and update actions for this Mac and the selected M5Paper, shown under the editor toolbar.
struct UpdateBanner: View {
    @ObservedObject var updates: UpdateService

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                icon
                VStack(alignment: .leading, spacing: 1) {
                    Text(headline)
                        .font(.system(size: 12, weight: highlighted ? .semibold : .regular))
                    Text(versions)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                actions
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(highlighted ? Color.accentColor.opacity(0.10) : Color.clear)
            Divider()
        }
    }

    private var highlighted: Bool {
        updates.activity != nil || updates.problem != nil || updates.notice != nil ||
            updates.appUpdate != nil || updates.firmwareUpdate != nil
    }

    @ViewBuilder private var icon: some View {
        if updates.activity != nil {
            ProgressView().controlSize(.small)
        } else if updates.problem != nil || updates.firmwareNeedsUSB {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        } else if updates.appUpdate != nil || updates.firmwareUpdate != nil {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
        } else {
            Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
        }
    }

    private var headline: String {
        if let activity = updates.activity {
            if case .installing(let item) = activity, item.hasPrefix("M5Paper") {
                return "Installing \(item)… the M5Paper shows progress and restarts when done."
            }
            return activity.title
        }
        if let problem = updates.problem { return problem }
        if let notice = updates.notice { return notice }
        if let release = updates.appUpdate {
            return "paperGIF Mac \(release.version) is available."
        }
        if let release = updates.firmwareUpdate {
            return updates.firmwareNeedsUSB
                ? "This M5Paper's firmware is too old for Wi-Fi updates. Flash \(release.version) over USB once."
                : "M5Paper firmware \(release.version) is available."
        }
        if updates.release == nil { return "Updates not checked yet" }
        return updates.deviceFirmware == nil ? "paperGIF Mac is up to date" : "Everything is up to date"
    }

    private var versions: String {
        let device = updates.deviceFirmware.map { "M5Paper firmware \($0)" } ?? "M5Paper not found"
        let latest = updates.release.map { " · Latest release \($0.version)" } ?? ""
        return "paperGIF Mac \(updates.currentAppVersion) · \(device)\(latest)"
    }

    @ViewBuilder private var actions: some View {
        if updates.activity == nil {
            if updates.problem != nil || updates.notice != nil {
                Button("Dismiss") { updates.dismissMessages() }
            }
            if updates.appUpdate != nil {
                Button("Install and Relaunch") { Task { await updates.installAppUpdate() } }
                    .buttonStyle(.borderedProminent)
            } else if updates.firmwareUpdate != nil && !updates.firmwareNeedsUSB {
                Button("Update M5Paper") { Task { await updates.installFirmwareUpdate() } }
                    .buttonStyle(.borderedProminent)
            }
            Button {
                Task { await updates.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Check for updates")
        }
    }
}
