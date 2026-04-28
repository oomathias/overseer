import Darwin
import Foundation

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
        throw OverseerError.system(
          "failed to submit notification: osascript exited with status \(process.terminationStatus)")
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
  typealias IdentityResolver = (Int32) -> ProcessSignalIdentity?
  typealias KillFunction = (pid_t, Int32) -> Int32

  private let identityResolver: IdentityResolver
  private let killFunction: KillFunction

  init(
    identityResolver: @escaping IdentityResolver = DarwinSignalSender.currentIdentity(pid:),
    killFunction: @escaping KillFunction = Darwin.kill
  ) {
    self.identityResolver = identityResolver
    self.killFunction = killFunction
  }

  func send(pid: Int32, signal: KillSignal, expectedIdentity: ProcessSignalIdentity) throws {
    guard let currentIdentity = identityResolver(pid) else {
      throw OverseerError.system("refusing to send \(signal.rawValue) to pid \(pid): process identity unavailable")
    }
    guard currentIdentity.startTime == expectedIdentity.startTime else {
      throw OverseerError.system("refusing to send \(signal.rawValue) to pid \(pid): process start time changed")
    }
    if let expectedExecutableName = expectedIdentity.executableName {
      guard
        let currentExecutableName = currentIdentity.executableName,
        currentExecutableName.caseInsensitiveCompare(expectedExecutableName) == .orderedSame
      else {
        throw OverseerError.system("refusing to send \(signal.rawValue) to pid \(pid): executable changed")
      }
    }

    let rawSignal: Int32
    switch signal {
    case .term:
      rawSignal = SIGTERM
    case .kill:
      rawSignal = SIGKILL
    case .int:
      rawSignal = SIGINT
    }

    if killFunction(pid_t(pid), rawSignal) != 0 {
      let message = String(cString: strerror(errno))
      throw OverseerError.system("failed to send \(signal.rawValue) to pid \(pid): \(message)")
    }
  }

  private static func currentIdentity(pid: Int32) -> ProcessSignalIdentity? {
    guard let startTime = currentStartTime(pid: pid) else {
      return nil
    }
    return ProcessSignalIdentity(startTime: startTime, executableName: currentExecutableName(pid: pid))
  }

  private static func currentStartTime(pid: Int32) -> ProcessStartTime? {
    var info = proc_bsdinfo()
    let filled = withUnsafeMutableBytes(of: &info) { bytes in
      proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, bytes.baseAddress, Int32(bytes.count))
    }
    if filled != Int32(MemoryLayout<proc_bsdinfo>.size) {
      return nil
    }
    return ProcessStartTime(
      seconds: max(Int64(0), Int64(clamping: info.pbi_start_tvsec)),
      microseconds: max(Int64(0), Int64(clamping: info.pbi_start_tvusec))
    )
  }

  private static func currentExecutableName(pid: Int32) -> String? {
    var pathBuffer = [CChar](repeating: 0, count: Int(PROC_PIDPATHINFO_SIZE))
    let copied = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
    if copied <= 0 {
      return nil
    }
    let raw = pathBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    let path = String(decoding: raw, as: UTF8.self)
    let name = (path as NSString).lastPathComponent
    return name.isEmpty ? nil : name
  }
}
