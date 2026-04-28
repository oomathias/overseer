import XCTest

@testable import overseer

final class ConfigSecurityTests: XCTestCase {
  func testValidationRejectsAllProcessKillRule() {
    let config = Config(
      pollIntervalSeconds: 5,
      onlyTreeRoots: true,
      notifyOnKill: true,
      warningThreshold: 0,
      rules: [
        Rule(
          process: nil,
          pidFileGlob: nil,
          metric: .memoryMB,
          threshold: 100,
          forSeconds: nil,
          action: .kill,
          signal: .term,
          cooldownSeconds: nil
        )
      ]
    )

    XCTAssertThrowsError(try config.validate())
  }

  func testValidationRejectsZeroThresholdKillRule() {
    let config = Config(
      pollIntervalSeconds: 5,
      onlyTreeRoots: true,
      notifyOnKill: true,
      warningThreshold: 0,
      rules: [
        Rule(
          process: "node",
          pidFileGlob: nil,
          metric: .memoryMB,
          threshold: 0,
          forSeconds: nil,
          action: .kill,
          signal: .term,
          cooldownSeconds: nil
        )
      ]
    )

    XCTAssertThrowsError(try config.validate())
  }

  func testValidationRejectsPIDFileOnlyKillRule() {
    let config = Config(
      pollIntervalSeconds: 5,
      onlyTreeRoots: true,
      notifyOnKill: true,
      warningThreshold: 0,
      rules: [
        Rule(
          process: nil,
          pidFileGlob: "/tmp/*.pid",
          metric: .memoryMB,
          threshold: 100,
          forSeconds: nil,
          action: .kill,
          signal: .term,
          cooldownSeconds: nil
        )
      ]
    )

    XCTAssertThrowsError(try config.validate())
  }
}
