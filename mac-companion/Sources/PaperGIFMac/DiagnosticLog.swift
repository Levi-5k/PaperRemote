import Foundation

struct DeviceLogBatch: Decodable {
    let deviceName: String
    let entries: [DeviceLogEntry]
}

struct DeviceLogEntry: Decodable {
    let timestamp: String
    let severity: String
    let message: String
}

enum DiagnosticLog {
    private static let queue = DispatchQueue(label: "paperGIF.diagnostic-log")
    private static let maximumBytes: UInt64 = 1_048_576

    static var directoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("paperGIF Mac", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
    }

    static func info(_ message: String) {
        appendProgramLine(level: "INFO", message: message)
    }

    static func error(_ message: String, error: Error? = nil) {
        let detail = error.map { "\(message): \($0)" } ?? message
        appendProgramLine(level: "ERROR", message: detail)
    }

    static func appendDeviceBatch(_ batch: DeviceLogBatch) throws {
        try queue.sync {
            let name = sanitizedFileComponent(batch.deviceName)
            let url = directoryURL.appendingPathComponent("device-\(name).log")
            let receivedAt = timestamp()
            let lines = batch.entries.map {
                "[\(receivedAt)] [device \($0.timestamp)] [\($0.severity.uppercased())] \($0.message)"
            }
            try append(lines: lines, to: url)
        }
    }

    private static func appendProgramLine(level: String, message: String) {
        queue.async {
            do {
                try append(
                    lines: ["[\(timestamp())] [\(level)] \(message)"],
                    to: directoryURL.appendingPathComponent("program-errors.log")
                )
            } catch {
                NSLog("Could not write paperGIF diagnostic log: %@", String(describing: error))
            }
        }
    }

    private static func append(lines: [String], to url: URL) throws {
        guard !lines.isEmpty else { return }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size >= maximumBytes {
            let previous = url.appendingPathExtension("previous")
            try? FileManager.default.removeItem(at: previous)
            try FileManager.default.moveItem(at: url, to: previous)
        }
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url, options: .atomic)
        }
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private static func sanitizedFileComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let sanitized = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        let result = String(sanitized).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return result.isEmpty ? "unknown" : String(result.prefix(64))
    }
}