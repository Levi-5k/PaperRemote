import SwiftUI
import UIKit

struct PaperGIFLegacyMusicExportSection: View {
    private struct ExportFolder: Identifiable {
        let id = UUID()
        let url: URL
    }

    private struct Notice {
        let title: String
        let message: String
    }

    @State private var isCheckingLibrary = false
    @State private var exportFolder: ExportFolder?
    @State private var didExport = false
    @State private var notice: Notice?

    var body: some View {
        Section {
            Button(action: exportLibrary) {
                Label("Export paperGIF Library", systemImage: "square.and.arrow.up")
            }
            .disabled(isCheckingLibrary || exportFolder != nil)

            if isCheckingLibrary {
                ProgressView("Checking legacy library…")
            }
        } header: {
            Text("Move Music to XPlayer")
        } footer: {
            Text("Save a copy of your legacy Music folder to Files. Then, in XPlayer, choose Import paperGIF Library and select the exported Music folder itself, not its parent or individual songs. Subfolders are preserved. The original library stays in paperGIF; do not delete this app until you verify the import.")
        }
        .sheet(item: $exportFolder, onDismiss: exportPickerDismissed) { folder in
            PaperGIFLegacyMusicExportPicker(root: folder.url) { exported in
                didExport = exported
                exportFolder = nil
            }
        }
        .alert(notice?.title ?? "Library Export", isPresented: Binding(
            get: { notice != nil },
            set: { if !$0 { notice = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(notice?.message ?? "")
        }
    }

    private func exportLibrary() {
        guard !isCheckingLibrary, exportFolder == nil else { return }
        isCheckingLibrary = true
        didExport = false
        Task {
            defer { isCheckingLibrary = false }
            do {
                let root = try await Task.detached(priority: .userInitiated) {
                    try PaperGIFLegacyMusicLibrary.exportRoot()
                }.value
                exportFolder = ExportFolder(url: root)
            } catch {
                notice = Notice(title: "Couldn’t Export Library", message: error.localizedDescription)
            }
        }
    }

    private func exportPickerDismissed() {
        guard didExport else { return }
        didExport = false
        notice = Notice(
            title: "Library Copy Exported",
            message: "In XPlayer, choose Import paperGIF Library and select the Music folder you just saved in Files. If you used iCloud Drive, wait for it to finish uploading before importing on another device. Your original paperGIF library has not been moved or deleted. Verify your songs and subfolders in XPlayer before removing paperGIF."
        )
    }
}

private struct PaperGIFLegacyMusicExportPicker: UIViewControllerRepresentable {
    let root: URL
    let onCompletion: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCompletion: onCompletion)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [root], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onCompletion: (Bool) -> Void

        init(onCompletion: @escaping (Bool) -> Void) {
            self.onCompletion = onCompletion
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onCompletion(!urls.isEmpty)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCompletion(false)
        }
    }
}