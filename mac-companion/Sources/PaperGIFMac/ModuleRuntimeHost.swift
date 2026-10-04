import Foundation

struct ModuleActionRequest: Codable {
    let type: String
    let host: String?
    let text: String
    let value: Int
    let valueTenths: Int?
    let modifiers: [String]
}

struct ModuleActionResponse: Codable {
    let succeeded: Bool
    let changed: Bool
    let message: String?
}

/// Management requests come only from this app's UI, never from M5Paper actions.
struct ModuleManageRequest: Encodable {
    let type = "manage"
    let command: String
    var setupCode: String?
    var name: String?
}

final class ModuleRuntimeHost: @unchecked Sendable {
    private struct RuntimeProcess {
        let process: Process
        let input: FileHandle
        let output: FileHandle
    }

    private let lock = NSLock()
    private let stateRoot: URL
    private var runtimeByModule: [String: String] = [:]
    private var commandsByModule: [String: Set<String>] = [:]
    private var processes: [String: RuntimeProcess] = [:]

    init(stateRoot: URL? = nil) {
        self.stateRoot = stateRoot ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("paperGIF Mac/module-state", isDirectory: true)
    }

    func load(_ manifests: [PaperModuleManifest]) {
        lock.lock()
        defer { lock.unlock() }
        runtimeByModule = manifests.reduce(into: [:]) { result, manifest in
            guard let runtime = manifest.runtime else { return }
            result[manifest.id] = runtime.executable
        }
        commandsByModule = manifests.reduce(into: [:]) { result, manifest in
            guard let runtime = manifest.runtime else { return }
            result[manifest.id] = Set(runtime.actions)
        }
        let activeRuntimes = Set(runtimeByModule.values)
        for name in processes.keys where !activeRuntimes.contains(name) {
            stopProcess(name)
        }
    }

    func perform(_ request: ModuleActionRequest) -> ModuleActionResponse? {
        lock.lock()
        defer { lock.unlock() }
          guard request.type == "module",
              let moduleID = request.host,
              let runtimeName = runtimeByModule[moduleID],
              commandsByModule[moduleID]?.contains(request.text) == true else { return nil }
        do {
            let runtime = try process(named: runtimeName)
            let payload = try JSONEncoder().encode(request) + Data([0x0A])
            try runtime.input.write(contentsOf: payload)
            guard let line = try runtime.output.readLine(maximumBytes: 64 * 1024) else {
                stopProcess(runtimeName)
                return ModuleActionResponse(
                    succeeded: false,
                    changed: false,
                    message: "Module runtime exited without a response"
                )
            }
            return try JSONDecoder().decode(ModuleActionResponse.self, from: line)
        } catch {
            stopProcess(runtimeName)
            return ModuleActionResponse(
                succeeded: false,
                changed: false,
                message: error.localizedDescription
            )
        }
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        for name in Array(processes.keys) {
            stopProcess(name)
        }
    }

    /// Blocks until the module replies; call off the main thread.
    func manage(moduleID: String, _ request: ModuleManageRequest) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard let runtimeName = runtimeByModule[moduleID] else {
            throw ModuleRuntimeError.moduleNotLoaded(moduleID)
        }
        do {
            let runtime = try process(named: runtimeName)
            try runtime.input.write(contentsOf: try JSONEncoder().encode(request) + Data([0x0A]))
            guard let line = try runtime.output.readLine(maximumBytes: 64 * 1024) else {
                throw ModuleRuntimeError.noResponse
            }
            return line
        } catch {
            stopProcess(runtimeName)
            throw error
        }
    }

    private func process(named name: String) throws -> RuntimeProcess {
        if let runtime = processes[name], runtime.process.isRunning {
            return runtime
        }
        guard let executableURL = executableURL(named: name) else {
            throw ModuleRuntimeError.executableNotFound(name)
        }
        let moduleState = stateRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: moduleState, withIntermediateDirectories: true)

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["--json-lines", "--state", moduleState.path]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.standardError
        try process.run()
        let runtime = RuntimeProcess(
            process: process,
            input: inputPipe.fileHandleForWriting,
            output: outputPipe.fileHandleForReading
        )
        processes[name] = runtime
        return runtime
    }

    private func executableURL(named name: String) -> URL? {
        let executableName = "PaperGIFModule-\(name)"
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: executableName) {
            return bundled
        }
        let sibling = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .appendingPathComponent(executableName)
        return FileManager.default.isExecutableFile(atPath: sibling.path) ? sibling : nil
    }

    private func stopProcess(_ name: String) {
        guard let runtime = processes.removeValue(forKey: name) else { return }
        try? runtime.input.close()
        if runtime.process.isRunning {
            runtime.process.terminate()
        }
    }
}

private enum ModuleRuntimeError: LocalizedError {
    case executableNotFound(String)
    case moduleNotLoaded(String)
    case noResponse

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let name):
            "The signed runtime for module \(name) is not installed."
        case .moduleNotLoaded(let id):
            "The \(id) module is not installed."
        case .noResponse:
            "Module runtime exited without a response"
        }
    }
}

private extension FileHandle {
    func readLine(maximumBytes: Int) throws -> Data? {
        var line = Data()
        while line.count < maximumBytes {
            guard let byte = try read(upToCount: 1), !byte.isEmpty else {
                return line.isEmpty ? nil : line
            }
            if byte[0] == 0x0A {
                return line
            }
            line.append(byte)
        }
        throw CocoaError(.fileReadTooLarge)
    }
}