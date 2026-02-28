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
        process.standardInput = nil
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw OverseerError.commandFailed("failed to launch \(program): \(error.localizedDescription)")
        }

        let stdoutBox = DataBox()
        let stderrBox = DataBox()

        let readGroup = DispatchGroup()
        readGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stdoutBox.set(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            readGroup.leave()
        }

        readGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stderrBox.set(stderrPipe.fileHandleForReading.readDataToEndOfFile())
            readGroup.leave()
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

        readGroup.wait()

        var stdoutData = stdoutBox.get()
        var stderrData = stderrBox.get()

        if stdoutData.count > maxOutputBytes {
            stdoutData = Data(stdoutData.prefix(maxOutputBytes))
        }
        if stderrData.count > maxOutputBytes {
            stderrData = Data(stderrData.prefix(maxOutputBytes))
        }

        let stdout = String(decoding: stdoutData, as: UTF8.self)
        let stderr = String(decoding: stderrData, as: UTF8.self)
        let exitCode: Int32 = timedOut ? -1 : process.terminationStatus

        return CommandOutput(stdout: stdout, stderr: stderr, exitCode: exitCode, timedOut: timedOut)
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func set(_ value: Data) {
        lock.lock()
        data = value
        lock.unlock()
    }

    func get() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
