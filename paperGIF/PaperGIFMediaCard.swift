import CoreGraphics
import SwiftUI

struct PaperGIFMediaCard: View {
    let savedMedia: PaperGIFStorage.SavedMedia
    let isSelected: Bool
    @ObservedObject var bluetoothManager: PaperGIFBluetoothManager
    let onChangeCrop: () -> Void
    let onEditConversion: () -> Void
    let onExport: () -> Void
    let onDelete: () -> Void

    @State private var animation: PaperGIFAnimation?
    @State private var previewImage: CGImage?
    @State private var confirmsDeletion = false

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
                        .disabled(!bluetoothManager.canSend)
                        .accessibilityLabel(sendButtonTitle)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(width: proxy.size.width, alignment: .leading)
                .background(.regularMaterial)
                .frame(height: proxy.size.height, alignment: .bottom)

                if isActiveTransfer {
                    ProgressView(value: bluetoothManager.transferProgress)
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
            .disabled(!bluetoothManager.canSend)

            Button(action: onExport) {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .tint(.indigo)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Delete", systemImage: "trash", role: .destructive) {
                confirmsDeletion = true
            }

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
            isPresented: $confirmsDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        }
        .task(id: savedMedia.savedAt) {
            let data = savedMedia.data
            let sourceData = savedMedia.sourceData
            guard let result = try? await Task.detached(priority: .utility, operation: {
                let animation = try PaperGIFAnimation(encoded: data)
                let image: CGImage
                if let sourceData {
                    image = try PaperGIFEncoder.previewImage(from: sourceData)
                } else {
                    guard let firstFrame = animation.frames.first else {
                        throw PaperGIFError.noFrames
                    }
                    image = try PaperGIFEncoder.previewImage(fromPackedFrame: firstFrame)
                }
                return (animation, image)
            }).value else { return }
            animation = result.0
            previewImage = result.1
        }
    }

    private func detail(for animation: PaperGIFAnimation) -> String {
        let kind = animation.frames.count == 1 ? "IMAGE" : "GIF"
        let size = ByteCountFormatter.string(fromByteCount: Int64(savedMedia.data.count), countStyle: .file)
        return "\(kind)  •  \(animation.frames.count) frame\(animation.frames.count == 1 ? "" : "s")  •  \(size)"
    }

    private func sendToDevice() {
        bluetoothManager.send(savedMedia.data, name: savedMedia.name, mediaID: savedMedia.id)
    }

    private var sendButtonTitle: String {
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
