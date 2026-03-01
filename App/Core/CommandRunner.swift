import Foundation
import Darwin

struct CommandOutput {
    let stdout: String
    let stderr: String
    let exitCode: Int32
    let timedOut: Bool
}

final class CommandRunner {
    func run(
        program: String,
        arguments: [String],
        timeout: TimeInterval,
        maxOutputBytes: Int = 1024 * 1024
    ) throws -> CommandOutput {
        let process = Process()
        if program.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: program)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [program] + arguments
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        process.standardInput = nil
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutBox = DataBox()
        let stderrBox = DataBox()

        stdoutHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            stdoutBox.append(chunk, maxBytes: maxOutputBytes)
        }

        stderrHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            stderrBox.append(chunk, maxBytes: maxOutputBytes)
        }

        do {
            try process.run()
        } catch {
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
            throw OverseerError.commandFailed("failed to launch \(program): \(error.localizedDescription)")
        }

        let waitSemaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            waitSemaphore.signal()
        }

        let timedOut = waitSemaphore.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            _ = waitSemaphore.wait(timeout: .now() + 1)
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = waitSemaphore.wait(timeout: .now() + 1)
            }
        }

        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil
        stdoutHandle.closeFile()
        stderrHandle.closeFile()

        let stdoutData = stdoutBox.get()
        let stderrData = stderrBox.get()

        let stdout = String(decoding: stdoutData, as: UTF8.self)
        let stderr = String(decoding: stderrData, as: UTF8.self)
        let exitCode: Int32 = timedOut ? -1 : process.terminationStatus

        return CommandOutput(stdout: stdout, stderr: stderr, exitCode: exitCode, timedOut: timedOut)
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ value: Data, maxBytes: Int) {
        lock.lock()
        defer { lock.unlock() }

        if data.count >= maxBytes || value.isEmpty {
            return
        }

        let remaining = maxBytes - data.count
        if value.count > remaining {
            data.append(value.prefix(remaining))
        } else {
            data.append(value)
        }
    }

    func get() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
