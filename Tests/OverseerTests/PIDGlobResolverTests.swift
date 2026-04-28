import XCTest

@testable import overseer

final class PIDGlobResolverTests: XCTestCase {
  func testResolveAbsolutePathRejectsUnexpandedUserPath() throws {
    XCTAssertThrowsError(
      try resolveAbsolutePath("~nosuchuser/config.json", currentDirectory: "/tmp/demo")
    ) { error in
      guard let overseerError = error as? OverseerError else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertEqual(
        overseerError.description,
        "failed to expand path ~nosuchuser/config.json"
      )
    }
  }

  func testConfigValidationRejectsUnexpandedPIDGlobUserPath() throws {
    let configData = """
      {
        "poll_interval_seconds": 5,
        "only_tree_roots": true,
        "notify_on_kill": true,
        "warning_threshold": 0,
        "rules": [
          {
            "pid_file_glob": "~nosuchuser/.agent-browser/*.pid",
            "metric": "memory_mb",
            "threshold": 100,
            "action": "notify"
          }
        ]
      }
      """.data(using: .utf8)!
    let config = try JSONDecoder().decode(Config.self, from: configData)

    XCTAssertThrowsError(try config.validate()) { error in
      guard let overseerError = error as? OverseerError else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertEqual(
        overseerError.description,
        "rule 0 has unexpandable pid_file_glob ~nosuchuser/.agent-browser/*.pid"
      )
    }
  }

  func testMissingPIDGlobDirectoryReturnsEmptyFilter() throws {
    let missingDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathComponent("missing")

    let rules = [
      Rule(
        process: nil,
        pidFileGlob: missingDirectory.appendingPathComponent("*.pid").path,
        metric: .memoryMB,
        threshold: 100,
        forSeconds: nil,
        action: .notify,
        signal: nil,
        cooldownSeconds: nil
      )
    ]

    let filters = PIDGlobResolver().resolveFilters(rules: rules)

    XCTAssertEqual(filters[0], PIDFilter(matches: [:]))
  }

  func testPIDGlobCollectsMatchingPIDs() throws {
    let tempDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDirectory) }

    let pidFile = tempDirectory.appendingPathComponent("browser.pid")
    try "12345\n".write(to: pidFile, atomically: true, encoding: .utf8)
    try "not a pid".write(
      to: tempDirectory.appendingPathComponent("ignored.pid"),
      atomically: true,
      encoding: .utf8
    )
    try "67890\n".write(
      to: tempDirectory.appendingPathComponent("other.txt"),
      atomically: true,
      encoding: .utf8
    )

    let rules = [
      Rule(
        process: nil,
        pidFileGlob: tempDirectory.appendingPathComponent("*.pid").path,
        metric: .memoryMB,
        threshold: 100,
        forSeconds: nil,
        action: .notify,
        signal: nil,
        cooldownSeconds: nil
      )
    ]

    let filters = PIDGlobResolver().resolveFilters(rules: rules)

    let match = try XCTUnwrap(filters[0]?.matches[12345])
    XCTAssertEqual(match.pid, 12345)
    XCTAssertEqual(match.filePath, pidFile.path)
  }

  func testPIDGlobCollectsSymlinkedPIDFiles() throws {
    let tempDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDirectory) }

    let target = tempDirectory.appendingPathComponent("target.txt")
    let pidFile = tempDirectory.appendingPathComponent("browser.pid")
    try "12345\n".write(to: target, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(atPath: pidFile.path, withDestinationPath: target.path)

    let rules = [
      Rule(
        process: nil,
        pidFileGlob: tempDirectory.appendingPathComponent("*.pid").path,
        metric: .memoryMB,
        threshold: 100,
        forSeconds: nil,
        action: .notify,
        signal: nil,
        cooldownSeconds: nil
      )
    ]

    let filters = PIDGlobResolver().resolveFilters(rules: rules)

    let match = try XCTUnwrap(filters[0]?.matches[12345])
    XCTAssertEqual(match.pid, 12345)
    XCTAssertEqual(match.filePath, pidFile.path)
  }

  func testPIDGlobIgnoresPIDFilesInWorldWritableDirectory() throws {
    let tempDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDirectory) }

    try "12345\n".write(
      to: tempDirectory.appendingPathComponent("browser.pid"),
      atomically: true,
      encoding: .utf8
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o777))],
      ofItemAtPath: tempDirectory.path
    )

    let rules = [
      Rule(
        process: nil,
        pidFileGlob: tempDirectory.appendingPathComponent("*.pid").path,
        metric: .memoryMB,
        threshold: 100,
        forSeconds: nil,
        action: .notify,
        signal: nil,
        cooldownSeconds: nil
      )
    ]

    let filters = PIDGlobResolver().resolveFilters(rules: rules)

    XCTAssertEqual(filters[0], PIDFilter(matches: [:]))
  }

  func testPIDGlobIgnoresPIDFilesInGroupWritableDirectory() throws {
    let tempDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDirectory) }

    try "12345\n".write(
      to: tempDirectory.appendingPathComponent("browser.pid"),
      atomically: true,
      encoding: .utf8
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o775))],
      ofItemAtPath: tempDirectory.path
    )

    let rules = [
      Rule(
        process: nil,
        pidFileGlob: tempDirectory.appendingPathComponent("*.pid").path,
        metric: .memoryMB,
        threshold: 100,
        forSeconds: nil,
        action: .notify,
        signal: nil,
        cooldownSeconds: nil
      )
    ]

    let filters = PIDGlobResolver().resolveFilters(rules: rules)

    XCTAssertEqual(filters[0], PIDFilter(matches: [:]))
  }

  func testPIDGlobCollectsGroupWritablePIDFiles() throws {
    let tempDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDirectory) }

    let pidFile = tempDirectory.appendingPathComponent("browser.pid")
    try "12345\n".write(to: pidFile, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o664))],
      ofItemAtPath: pidFile.path
    )

    let rules = [
      Rule(
        process: nil,
        pidFileGlob: tempDirectory.appendingPathComponent("*.pid").path,
        metric: .memoryMB,
        threshold: 100,
        forSeconds: nil,
        action: .notify,
        signal: nil,
        cooldownSeconds: nil
      )
    ]

    let filters = PIDGlobResolver().resolveFilters(rules: rules)

    let match = try XCTUnwrap(filters[0]?.matches[12345])
    XCTAssertEqual(match.pid, 12345)
    XCTAssertEqual(match.filePath, pidFile.path)
  }

  func testPIDGlobIgnoresSymlinkedDirectories() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    let realDirectory = root.appendingPathComponent("real", isDirectory: true)
    let symlinkDirectory = root.appendingPathComponent("link", isDirectory: true)
    try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try "12345\n".write(
      to: realDirectory.appendingPathComponent("browser.pid"),
      atomically: true,
      encoding: .utf8
    )
    try FileManager.default.createSymbolicLink(
      atPath: symlinkDirectory.path,
      withDestinationPath: realDirectory.path
    )

    let rules = [
      Rule(
        process: nil,
        pidFileGlob: symlinkDirectory.appendingPathComponent("*.pid").path,
        metric: .memoryMB,
        threshold: 100,
        forSeconds: nil,
        action: .notify,
        signal: nil,
        cooldownSeconds: nil
      )
    ]

    let filters = PIDGlobResolver().resolveFilters(rules: rules)

    XCTAssertEqual(filters[0], PIDFilter(matches: [:]))
  }

  func testPIDFilterRejectsProcessesStartedAfterPIDFileWasWritten() {
    let pid = Int32(12345)
    let filter = PIDFilter(
      matches: [
        pid: PIDFileMatch(
          pid: pid,
          filePath: "/tmp/browser.pid",
          modifiedAt: Date(timeIntervalSince1970: 100)
        )
      ]
    )
    let process = overseer.ProcessInfo(
      pid: pid,
      ppid: 1,
      name: "browser",
      nameSource: .executablePath,
      command: "/usr/local/bin/browser",
      startTime: ProcessStartTime(seconds: 101, microseconds: 0),
      cpuPercent: 0,
      rssKB: 0,
      elapsedSeconds: 0
    )

    XCTAssertFalse(filter.contains(process: process))
  }
}
