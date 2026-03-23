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
            ),
        ]

        let filters = PIDGlobResolver().resolveFilters(rules: rules)

        XCTAssertEqual(filters[0], [])
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
            ),
        ]

        let filters = PIDGlobResolver().resolveFilters(rules: rules)

        XCTAssertEqual(filters[0], Set([12345]))
    }
}
