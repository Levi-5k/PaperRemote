import Darwin
import Foundation

struct BoundedProcessResult {
    let status: Int32
    let output: Data
    let errorOutput: Data
    let timedOut: Bool
}

enum BoundedProcessRunner {
    static func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        captureOutput: Bool = true,
        timeout: TimeInterval = 30,
        maximumOutputBytes: Int = 64 * 1024
    ) throws -> BoundedProcessResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let lock = NSLock()
        var output = Data()
        var errorOutput = Data()
        let drains = DispatchGroup()

        if captureOutput {
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            installDrain(
                for: outputPipe.fileHandleForReading,
                group: drains,
                lock: lock,
                destination: { data in
                    output.append(data.prefix(max(0, maximumOutputBytes - output.count)))
                }
            )
            installDrain(
                for: errorPipe.fileHandleForReading,
                group: drains,
                lock: lock,
                destination: { data in
                    errorOutput.append(data.prefix(max(0, maximumOutputBytes - errorOutput.count)))
                }
            )
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }

        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }
        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }

        var timedOut = terminated.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            if terminated.wait(timeout: .now() + 0.5) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = terminated.wait(timeout: .now() + 2)
            }
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            timedOut = true
        }
        if captureOutput {
            _ = drains.wait(timeout: .now() + 1)
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
        }

        lock.lock()
        let result = BoundedProcessResult(
            status: process.terminationStatus,
            output: output,
            errorOutput: errorOutput,
            timedOut: timedOut
        )
        lock.unlock()
        return result
    }

    private static func installDrain(
        for handle: FileHandle,
        group: DispatchGroup,
        lock: NSLock,
        destination: @escaping (Data) -> Void
    ) {
        group.enter()
        var finished = false
        handle.readabilityHandler = { readableHandle in
            let data = readableHandle.availableData
            lock.lock()
            defer { lock.unlock() }
            if data.isEmpty {
                guard !finished else { return }
                finished = true
                readableHandle.readabilityHandler = nil
                group.leave()
                return
            }
            destination(data)
        }
    }
}
