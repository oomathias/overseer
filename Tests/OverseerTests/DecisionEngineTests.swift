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
      pidFilters: [0: Set([99])]
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

  private func process(
    pid: Int32,
    ppid: Int32,
    name: String,
    cpuPercent: Double = 0,
    rssKB: UInt64 = 0,
    elapsedSeconds: UInt64 = 0
  ) -> overseer.ProcessInfo {
    overseer.ProcessInfo(
      pid: pid,
      ppid: ppid,
      name: name,
      command: "/usr/bin/\(name)",
      cpuPercent: cpuPercent,
      rssKB: rssKB,
      elapsedSeconds: elapsedSeconds
    )
  }
}
