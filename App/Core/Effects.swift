import Foundation
import Darwin

struct AppleNotifier {
    func notify(kind: NotificationKind, message: String) throws {
        let escapedTitle = escapeAppleScriptString(title(for: kind))
        let escapedMessage = escapeAppleScriptString(message)
        let script = "display notification \"\(escapedMessage)\" with title \"\(escapedTitle)\""

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw OverseerError.system("failed to launch osascript for notification: \(error.localizedDescription)")
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrText = String(decoding: stderrData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if stderrText.isEmpty {
                throw OverseerError.system("failed to submit notification: osascript exited with status \(process.terminationStatus)")
            }
            throw OverseerError.system("failed to submit notification: \(stderrText)")
        }
    }

    private func title(for kind: NotificationKind) -> String {
        switch kind {
        case .warning:
            return "Overseer Warning"
        case .kill:
            return "Overseer Kill"
        case .monitor:
            return "Overseer Monitor"
        }
    }

    private func escapeAppleScriptString(_ input: String) -> String {
        var output = String()
        output.reserveCapacity(input.count)

        for character in input {
            switch character {
            case "\\":
                output.append("\\\\")
            case "\"":
                output.append("\\\"")
            case "\n", "\r":
                output.append(" ")
            default:
                output.append(character)
            }
        }

        return output
    }
}

struct DarwinSignalSender {
    func send(pid: Int32, signal: KillSignal) throws {
        let rawSignal: Int32
        switch signal {
        case .term:
            rawSignal = SIGTERM
        case .kill:
            rawSignal = SIGKILL
        case .int:
            rawSignal = SIGINT
        }

        if Darwin.kill(pid_t(pid), rawSignal) != 0 {
            let message = String(cString: strerror(errno))
            throw OverseerError.system("failed to send \(signal.rawValue) to pid \(pid): \(message)")
        }
    }
}
