import SwiftUI

/// Toolbar entry point: quiet when everything is current, highlighted when an update is ready.
struct UpdatesToolbarButton: View {
    @ObservedObject var updates: UpdateService

    private var hasUpdate: Bool { updates.appUpdate != nil || updates.firmwareUpdate != nil }

    var body: some View {
        Button {
            updates.isShowingUpdates = true
        } label: {
            HStack(spacing: 5) {
                if updates.activity != nil {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: hasUpdate ? "arrow.down.circle.fill" : "arrow.down.circle")
                        .foregroundStyle(hasUpdate ? Color.accentColor : .secondary)
                        .overlay(alignment: .topTrailing) {
                            if updates.problem != nil {
                                Circle().fill(.orange).frame(width: 7, height: 7).offset(x: 3, y: -3)
                            }
                        }
                }
                if hasUpdate && updates.activity == nil {
                    Text("Update")
                }
            }
        }
        .help(helpText)
    }

    private var helpText: String {
        if let activity = updates.activity { return activity.title }
        if hasUpdate { return "An update is ready to install" }
        return "Software updates"
    }
}

/// Versions, update actions, and release notes for this Mac and the selected M5Paper.
struct UpdatesPage: View {
    @ObservedObject var updates: UpdateService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    messages
                    UpdateCard(
                        symbol: "macwindow",
                        title: "paperGIF Mac",
                        detail: versionLine(installed: updates.currentAppVersion),
                        status: appStatus
                    ) {
                        if updates.appUpdate != nil && updates.activity == nil {
                            Button("Install and Relaunch") { Task { await updates.installAppUpdate() } }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    UpdateCard(
                        symbol: "rectangle.portrait",
                        title: "M5Paper",
                        detail: updates.deviceFirmware.map { versionLine(installed: $0) } ?? "Firmware version unknown",
                        status: firmwareStatus
                    ) {
                        if updates.activity == nil {
                            if updates.deviceFirmware == nil {
                                Button("Find M5Paper") { Task { await updates.refreshDevice() } }
                            } else if updates.firmwareUpdate != nil && !updates.firmwareNeedsUSB {
                                Button("Update M5Paper") { Task { await updates.installFirmwareUpdate() } }
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                    }
                    releaseNotes
                }
                .padding(20)
            }
            Divider()
            HStack {
                if let pageURL = updates.release?.pageURL {
                    Link("View Release on GitHub", destination: pageURL)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 560, height: 580)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(Color(red: 0.08, green: 0.35, blue: 0.42))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text("Software Updates").font(.title3.weight(.semibold))
                lastCheckedText.font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await updates.refresh() }
            } label: {
                if updates.activity == .checking {
                    ProgressView().controlSize(.small).frame(width: 74)
                } else {
                    Label("Check Now", systemImage: "arrow.clockwise")
                }
            }
            .disabled(updates.activity != nil)
        }
        .padding(20)
    }

    private var lastCheckedText: Text {
        guard let lastChecked = updates.lastChecked else {
            return Text(updates.activity == .checking ? "Checking…" : "Not checked yet")
        }
        return Text("Last checked ") + Text(lastChecked, style: .relative) + Text(" ago")
    }

    @ViewBuilder private var messages: some View {
        if let problem = updates.problem {
            Callout(symbol: "exclamationmark.triangle.fill", tint: .orange, text: problem) {
                updates.dismissMessages()
            }
        } else if let notice = updates.notice {
            Callout(symbol: "checkmark.seal.fill", tint: .green, text: notice) {
                updates.dismissMessages()
            }
        }
    }

    @ViewBuilder private var releaseNotes: some View {
        if let release = updates.release,
           !release.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("What's new in \(release.version)").font(.headline)
                Text(Self.renderedNotes(release.notes))
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 4)
        }
    }

    private func versionLine(installed: String) -> String {
        guard let latest = updates.release?.version else { return "Version \(installed)" }
        return "Version \(installed) · Latest \(latest)"
    }

    private var appStatus: UpdateStatus {
        if let activity = updates.activity, activity.item.hasPrefix("paperGIF Mac") {
            return .working(activity.title)
        }
        if let release = updates.appUpdate { return .available("Version \(release.version) is ready to install.") }
        return updates.release == nil ? .unknown("Not checked yet.") : .upToDate
    }

    private var firmwareStatus: UpdateStatus {
        if let activity = updates.activity, activity.item.hasPrefix("M5Paper") {
            if case .installing = activity {
                return .working("\(activity.title) The M5Paper shows progress and restarts when done.")
            }
            return .working(activity.title)
        }
        guard updates.deviceFirmware != nil else {
            return .attention("Not found on the network. Wake the M5Paper, then try again.")
        }
        if let release = updates.firmwareUpdate {
            return updates.firmwareNeedsUSB
                ? .attention("Too old for Wi-Fi updates. Flash \(release.version) over USB once; later updates install from here.")
                : .available("Firmware \(release.version) is ready to install over Wi-Fi.")
        }
        return updates.release == nil ? .unknown("Not checked yet.") : .upToDate
    }

    private static func renderedNotes(_ notes: String) -> AttributedString {
        (try? AttributedString(
            markdown: notes,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(notes)
    }
}

private enum UpdateStatus {
    case upToDate
    case available(String)
    case working(String)
    case attention(String)
    case unknown(String)
}

private struct UpdateCard<Actions: View>: View {
    let symbol: String
    let title: String
    let detail: String
    let status: UpdateStatus
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .foregroundStyle(Color(red: 0.08, green: 0.35, blue: 0.42))
                .frame(width: 44, height: 44)
                .background(Color(red: 0.08, green: 0.35, blue: 0.42).opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title).font(.headline)
                    chip
                }
                Text(detail).font(.callout).foregroundStyle(.secondary)
                if let message {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if case .working = status { ProgressView().controlSize(.small) }
                        Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 8)
            actions()
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.18)))
    }

    private var message: String? {
        switch status {
        case .upToDate: nil
        case .available(let text), .working(let text), .attention(let text), .unknown(let text): text
        }
    }

    private var chip: some View {
        let (label, tint): (String, Color) = switch status {
        case .upToDate: ("Up to date", .green)
        case .available: ("Update available", .accentColor)
        case .working: ("In progress", .accentColor)
        case .attention: ("Needs attention", .orange)
        case .unknown: ("Unknown", .secondary)
        }
        return Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(tint.opacity(0.14))
            .clipShape(Capsule())
    }
}

private struct Callout: View {
    let symbol: String
    let tint: Color
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Dismiss", action: dismiss)
        }
        .padding(12)
        .background(tint.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
