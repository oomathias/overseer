import XCTest

@testable import overseer

final class DecisionEngineTests: XCTestCase {
  func testWarningEmitsOnceUntilMetricDropsBelowWarningThreshold() {
    let engine = DecisionEngine()
    let config = Config(
      pollIntervalSeconds: 5,
      onlyTreeRoots: false,
      notifyOnKill: true,
      warningThreshold: 90,
      rules: [
        Rule(
          process: "node",
          pidFileGlob: nil,
          metric: .cpuPercent,
          threshold: 100,
          forSeconds: nil,
          action: .notify,
          signal: nil,
          cooldownSeconds: nil
        )
      ]
    )

    let warningProcess = process(pid: 42, ppid: 1, name: "node", cpuPercent: 95)
    let cooledProcess = process(pid: 42, ppid: 1, name: "node", cpuPercent: 80)

    let first = engine.evaluate(config: config, now: 1, processes: [warningProcess], pidFilters: [:])
    let expectedWarning: [EffectEvent] = [
      .warning(
        message:
          "node pid=42 metric=cpu_percent value=95.00 reached 90% of threshold=100.00")
    ]
    XCTAssertEqual(
      first.effects,
      expectedWarning
    )

    let second = engine.evaluate(config: config, now: 2, processes: [warningProcess], pidFilters: [:])
    XCTAssertTrue(second.effects.isEmpty)

    _ = engine.evaluate(config: config, now: 3, processes: [cooledProcess], pidFilters: [:])

    let third = engine.evaluate(config: config, now: 4, processes: [warningProcess], pidFilters: [:])
    XCTAssertEqual(third.effects, expectedWarning)
  }

  func testNotifyDefaultCooldownSuppressesRepeatedEffectsForSixtySeconds() {
    let engine = DecisionEngine()
    let config = Config(
      pollIntervalSeconds: 5,
      onlyTreeRoots: false,
      notifyOnKill: true,
      warningThreshold: 0,
      rules: [
        Rule(
          process: "node",
          pidFileGlob: nil,
          metric: .cpuPercent,
          threshold: 100,
          forSeconds: nil,
          action: .notify,
          signal: nil,
          cooldownSeconds: nil
        )
      ]
    )

    let hotProcess = process(pid: 42, ppid: 1, name: "node", cpuPercent: 120)
    let first = engine.evaluate(config: config, now: 10, processes: [hotProcess], pidFilters: [:])
    let expectedNotify: [EffectEvent] = [
      .notify(message: "node pid=42 metric=cpu_percent value=120.00 threshold=100.00")
    ]
    XCTAssertEqual(
      first.effects,
      expectedNotify
    )

    let suppressed = engine.evaluate(config: config, now: 69, processes: [hotProcess], pidFilters: [:])
    XCTAssertTrue(suppressed.effects.isEmpty)

    let retriggered = engine.evaluate(config: config, now: 70, processes: [hotProcess], pidFilters: [:])
    XCTAssertEqual(retriggered.effects, expectedNotify)
  }

  func testOnlyTreeRootsSkipsMatchingChildrenWhenParentAlsoMatches() {
    let engine = DecisionEngine()
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
          threshold: 100,
          forSeconds: nil,
          action: .notify,
          signal: nil,
          cooldownSeconds: nil
        )
      ]
    )

    let parent = process(pid: 10, ppid: 1, name: "node", rssKB: 200 * 1024)
    let child = process(pid: 11, ppid: 10, name: "node", rssKB: 300 * 1024)

    let output = engine.evaluate(config: config, now: 1, processes: [parent, child], pidFilters: [:])
    let expectedEffects: [EffectEvent] = [
      .notify(message: "node pid=10 metric=memory_mb value=200.00 threshold=100.00")
    ]

    XCTAssertEqual(
      output.tracks,
      [
        TrackEvent(
          ruleProcess: "node",
          pid: 10,
          metric: .memoryMB,
          value: 200,
          threshold: 100,
          forSeconds: nil,
          status: .violating
        )
      ]
    )
    XCTAssertEqual(output.effects, expectedEffects)
  }

  func testPIDFiltersLimitRulesToResolvedPIDs() {
    let engine = DecisionEngine()
    let config = Config(
      pollIntervalSeconds: 5,
      onlyTreeRoots: false,
      notifyOnKill: true,
      warningThreshold: 0,
      rules: [
        Rule(
          process: "node",
          pidFileGlob: nil,
          metric: .memoryMB,
          threshold: 100,
          forSeconds: nil,
          action: .notify,
          signal: nil,
          cooldownSeconds: nil
        )
      ]
    )

    let ignored = process(pid: 98, ppid: 1, name: "node", rssKB: 200 * 1024)
    let matched = process(pid: 99, ppid: 1, name: "node", rssKB: 250 * 1024)

    let output = engine.evaluate(
      config: config,
      now: 1,
      processes: [ignored, matched],
      pidFilters: [0: freshPIDFilter(pid: 99, processStartTime: matched.startTime)]
    )
    let expectedEffects: [EffectEvent] = [
      .notify(message: "node pid=99 metric=memory_mb value=250.00 threshold=100.00")
    ]

    XCTAssertEqual(
      output.tracks,
      [
        TrackEvent(
          ruleProcess: "node",
          pid: 99,
          metric: .memoryMB,
          value: 250,
          threshold: 100,
          forSeconds: nil,
          status: .violating
        )
      ]
    )
    XCTAssertEqual(output.effects, expectedEffects)
    XCTAssertTrue(output.matchedAny)
  }

  func testKillEffectsCarryStableProcessIdentityForRevalidation() {
    let engine = DecisionEngine()
    let config = Config(
      pollIntervalSeconds: 5,
      onlyTreeRoots: false,
      notifyOnKill: true,
      warningThreshold: 0,
      rules: [
        Rule(
          process: "node",
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

    let startTime = ProcessStartTime(seconds: 300, microseconds: 12)
    let output = engine.evaluate(
      config: config,
      now: 1,
      processes: [
        process(
          pid: 100,
          ppid: 1,
          name: "node",
          command: "/usr/local/bin/node",
          startTime: startTime,
          rssKB: 250 * 1024
        )
      ],
      pidFilters: [:]
    )

    XCTAssertEqual(
      output.effects,
      [
        .kill(
          pid: 100,
          signal: .term,
          processName: "node",
          expectedIdentity: ProcessSignalIdentity(startTime: startTime, executableName: "node"),
          message: "node pid=100 metric=memory_mb value=250.00 threshold=100.00",
          notifyUser: true
        )
      ]
    )
  }

  func testProcessRuleDoesNotMatchPathSubstringWhenBinaryNameDiffers() {
    let engine = DecisionEngine()
    let config = Config(
      pollIntervalSeconds: 5,
      onlyTreeRoots: false,
      notifyOnKill: true,
      warningThreshold: 0,
      rules: [
        Rule(
          process: "opencode",
          pidFileGlob: nil,
          metric: .memoryMB,
          threshold: 100,
          forSeconds: nil,
          action: .notify,
          signal: nil,
          cooldownSeconds: nil
        )
      ]
    )

    let output = engine.evaluate(
      config: config,
      now: 1,
      processes: [
        process(pid: 100, ppid: 1, name: "op", command: "/usr/local/bin/opencode", rssKB: 250 * 1024)
      ],
      pidFilters: [:]
    )

    XCTAssertTrue(output.tracks.isEmpty)
    XCTAssertTrue(output.effects.isEmpty)
    XCTAssertFalse(output.matchedAny)
  }

  func testProcessRuleRequiresExactExecutableBinaryNameByDefault() {
    let engine = DecisionEngine()
    let config = Config(
      pollIntervalSeconds: 5,
      onlyTreeRoots: false,
      notifyOnKill: true,
      warningThreshold: 0,
      rules: [
        Rule(
          process: "openc",
          pidFileGlob: nil,
          metric: .memoryMB,
          threshold: 100,
          forSeconds: nil,
          action: .notify,
          signal: nil,
          cooldownSeconds: nil
        )
      ]
    )

    let output = engine.evaluate(
      config: config,
      now: 1,
      processes: [
        process(
          pid: 101,
          ppid: 1,
          name: "opencode",
          command: "/usr/local/bin/opencode",
          rssKB: 250 * 1024
        )
      ],
      pidFilters: [:]
    )

    XCTAssertTrue(output.tracks.isEmpty)
    XCTAssertTrue(output.effects.isEmpty)
    XCTAssertFalse(output.matchedAny)
  }

  func testProcessRuleCanMatchFallbackNameWhenExecutablePathIsUnavailable() {
    let engine = DecisionEngine()
    let config = Config(
      pollIntervalSeconds: 5,
      onlyTreeRoots: false,
      notifyOnKill: true,
      warningThreshold: 0,
      rules: [
        Rule(
          process: "node",
          pidFileGlob: nil,
          metric: .memoryMB,
          threshold: 100,
          forSeconds: nil,
          action: .notify,
          signal: nil,
          cooldownSeconds: nil
        )
      ]
    )

    let output = engine.evaluate(
      config: config,
      now: 1,
      processes: [
        process(
          pid: 102,
          ppid: 1,
          name: "",
          command: "node",
          nameSource: .executablePath,
          rssKB: 250 * 1024
        )
      ],
      pidFilters: [:]
    )

    XCTAssertEqual(
      output.effects,
      [
        .notify(message: "node pid=102 metric=memory_mb value=250.00 threshold=100.00")
      ]
    )
    XCTAssertTrue(output.matchedAny)
  }

  func testPIDFileOnlyKillRuleDoesNotEmitKillWithoutExecutableIdentity() {
    let engine = DecisionEngine()
    let config = Config(
      pollIntervalSeconds: 5,
      onlyTreeRoots: false,
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

    let startTime = ProcessStartTime(seconds: 200, microseconds: 0)
    let output = engine.evaluate(
      config: config,
      now: 1,
      processes: [
        process(
          pid: 103,
          ppid: 1,
          name: "node",
          command: "node",
          nameSource: .bsdComm,
          startTime: startTime,
          rssKB: 250 * 1024
        )
      ],
      pidFilters: [0: freshPIDFilter(pid: 103, processStartTime: startTime)]
    )

    XCTAssertTrue(output.effects.isEmpty)
    XCTAssertFalse(output.matchedAny)
  }

  func testPIDFilterRejectsPIDFileOlderThanProcessStartTime() {
    let engine = DecisionEngine()
    let config = Config(
      pollIntervalSeconds: 5,
      onlyTreeRoots: false,
      notifyOnKill: true,
      warningThreshold: 0,
      rules: [
        Rule(
          process: nil,
          pidFileGlob: "/tmp/*.pid",
          metric: .memoryMB,
          threshold: 100,
          forSeconds: nil,
          action: .notify,
          signal: nil,
          cooldownSeconds: nil
        )
      ]
    )

    let processStartTime = ProcessStartTime(seconds: 200, microseconds: 0)
    let output = engine.evaluate(
      config: config,
      now: 1,
      processes: [
        process(pid: 101, ppid: 1, name: "node", startTime: processStartTime, rssKB: 250 * 1024)
      ],
      pidFilters: [0: stalePIDFilter(pid: 101, processStartTime: processStartTime)]
    )

    XCTAssertTrue(output.tracks.isEmpty)
    XCTAssertTrue(output.effects.isEmpty)
    XCTAssertFalse(output.matchedAny)
  }

  private func process(
    pid: Int32,
    ppid: Int32,
    name: String,
    command: String? = nil,
    nameSource: ProcessNameSource = .executablePath,
    startTime: ProcessStartTime = ProcessStartTime(seconds: 0, microseconds: 0),
    cpuPercent: Double = 0,
    rssKB: UInt64 = 0,
    elapsedSeconds: UInt64 = 0
  ) -> overseer.ProcessInfo {
    overseer.ProcessInfo(
      pid: pid,
      ppid: ppid,
      name: name,
      nameSource: nameSource,
      command: command ?? "/usr/bin/\(name)",
      startTime: startTime,
      cpuPercent: cpuPercent,
      rssKB: rssKB,
      elapsedSeconds: elapsedSeconds
    )
  }

  private func freshPIDFilter(pid: Int32, processStartTime: ProcessStartTime) -> PIDFilter {
    PIDFilter(
      matches: [
        pid: PIDFileMatch(
          pid: pid,
          filePath: "/tmp/\(pid).pid",
          modifiedAt: Date(timeIntervalSince1970: processStartTime.timeIntervalSince1970 + 1)
        )
      ]
    )
  }

  private func stalePIDFilter(pid: Int32, processStartTime: ProcessStartTime) -> PIDFilter {
    PIDFilter(
      matches: [
        pid: PIDFileMatch(
          pid: pid,
          filePath: "/tmp/\(pid).pid",
          modifiedAt: Date(timeIntervalSince1970: processStartTime.timeIntervalSince1970 - 1)
        )
      ]
    )
  }
}
