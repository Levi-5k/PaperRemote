import CoreGraphics
import PaperDeviceKit
import SwiftUI

struct PaperGIFMediaCard: View {
    let savedMedia: PaperGIFStorage.SavedMedia
    let isSelected: Bool
    @ObservedObject var bluetoothManager: PaperGIFBluetoothManager
    let descriptor: DeviceDescriptor?
    var effectsLive = false
    let onChangeCrop: () -> Void
    let onEditConversion: () -> Void
    let onExport: () -> Void
    @Binding var isConfirmingDeletion: Bool
    let onDelete: () -> Void

    @State private var animation: PaperGIFAnimation?
    @State private var previewImage: CGImage?
    @State private var preparingSend = false
    @State private var sendError: String?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(uiColor: .secondarySystemBackground)

                if let previewImage {
                    Image(decorative: previewImage, scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                } else {
                    ProgressView()
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(savedMedia.name)
                                .font(.headline)
                                .lineLimit(1)

                            if let animation {
                                Text(detail(for: animation))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            } else if savedMedia.isColorImage {
                                Text("IMAGE  •  \(ByteCountFormatter.string(fromByteCount: Int64(savedMedia.byteCount), countStyle: .file))")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }

                        if !savedMedia.isEditable {
                            Image(systemName: "lock")
                                .foregroundStyle(.secondary)
                        }

                        Button {
                            sendToDevice()
                        } label: {
                            Label(sendButtonTitle, systemImage: sendButtonIcon)
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canSend)
                        .accessibilityLabel(sendButtonTitle)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(width: proxy.size.width, alignment: .leading)
                .background(.regularMaterial)
                .frame(height: proxy.size.height, alignment: .bottom)

                if isActiveTransfer {
                    Group {
                        if effectsLive {
                            PaperGIFTransferBar(
                                fraction: bluetoothManager.transferProgress,
                                label: bluetoothManager.transferStatus ?? "Sending"
                            )
                        } else {
                            ProgressView(value: bluetoothManager.transferProgress)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: proxy.size.height, alignment: .top)
                    .padding(.top, 8)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(isActiveTransfer ? Color.blue : (isSelected ? Color.accentColor : .clear), lineWidth: 2)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                sendToDevice()
            } label: {
                Label("Send", systemImage: "antenna.radiowaves.left.and.right")
            }
            .tint(.blue)
            .disabled(!canSend)

            Button(action: onExport) {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .tint(.indigo)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // A destructive role removes the row before the confirmation can present.
            Button("Delete", systemImage: "trash") {
                isConfirmingDeletion = true
            }
            .tint(.red)

            Button(action: onEditConversion) {
                Label("Values", systemImage: "slider.horizontal.3")
            }
            .tint(.orange)
            .disabled(!savedMedia.isEditable)

            Button(action: onChangeCrop) {
                Label("Crop", systemImage: "crop")
            }
            .tint(.teal)
            .disabled(!savedMedia.isEditable)
        }
        .confirmationDialog(
            "Delete \(savedMedia.name)?",
            isPresented: $isConfirmingDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        }
        .task(id: savedMedia.savedAt) {
            guard let result = try? await Task.detached(priority: .utility, operation: {
                let loaded = try PaperGIFStorage.load(savedMedia)
                let data = loaded.data
                let animation = savedMedia.isColorImage ? nil : try PaperGIFAnimation(encoded: data)
                let image: CGImage
                if let sourceData = loaded.sourceData {
                    image = try PaperGIFEncoder.previewImage(from: sourceData)
                } else if savedMedia.isColorImage {
                    image = try DeviceImageEncoder.decode(data)
                } else {
                    guard let firstFrame = animation?.frames.first else {
                        throw PaperGIFError.noFrames
                    }
                    image = try PaperGIFEncoder.previewImage(fromPackedFrame: firstFrame)
                }
                return (animation, image)
            }).value else { return }
            animation = result.0
            previewImage = result.1
        }
        .alert("Couldn’t Send Media", isPresented: Binding(get: { sendError != nil }, set: { if !$0 { sendError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(sendError ?? "Unknown error") }
    }

    private func detail(for animation: PaperGIFAnimation) -> String {
        let kind = animation.frames.count == 1 ? "IMAGE" : "GIF"
        let size = ByteCountFormatter.string(fromByteCount: Int64(savedMedia.byteCount), countStyle: .file)
        return "\(kind)  •  \(animation.frames.count) frame\(animation.frames.count == 1 ? "" : "s")  •  \(size)"
    }

    private func sendToDevice() {
        guard canSend else { return }
        let targetID = descriptor?.deviceID
        let colorDisplay = descriptor?.canUseColorImages == true ? descriptor?.display : nil
        preparingSend = true
        Task {
            defer { preparingSend = false }
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    try PaperGIFStorage.load(savedMedia).convertedData(for: colorDisplay)
                }.value
                guard bluetoothManager.deviceSession?.selectedID == targetID else { return }
                if colorDisplay != nil, let targetID {
                    bluetoothManager.sendColorImage(data, to: targetID, name: savedMedia.name, mediaID: savedMedia.id)
                } else {
                    bluetoothManager.send(data, name: savedMedia.name, mediaID: savedMedia.id)
                }
            } catch { sendError = error.localizedDescription }
        }
    }

    private var canSend: Bool {
        !preparingSend && (descriptor?.canUseColorImages == true ? bluetoothManager.canSendColorImage : bluetoothManager.canSend)
    }

    private var sendButtonTitle: String {
        if preparingSend { return "Preparing" }
        if isActiveTransfer {
            return "Sending"
        }
        return bluetoothManager.connectionState == .connected ? "Send" : "Offline"
    }

    private var sendButtonIcon: String {
        if isActiveTransfer {
            return "arrow.up.circle"
        }
        if bluetoothManager.wifiConnectionState == .connected {
            return "wifi"
        }
        return bluetoothManager.connectionState == .connected
            ? "antenna.radiowaves.left.and.right"
            : "antenna.radiowaves.left.and.right.slash"
    }

    private var isActiveTransfer: Bool {
        bluetoothManager.isTransferring && bluetoothManager.transferMediaID == savedMedia.id
    }
}
