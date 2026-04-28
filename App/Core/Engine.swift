import Foundation

private struct ViolationKey: Hashable {
  let ruleIndex: Int
  let pid: Int32
}

private struct ViolationState {
  var firstViolationAt: UInt64
  var lastActionAt: UInt64
}

final class DecisionEngine {
  private var violations: [ViolationKey: ViolationState] = [:]
  private var warned: Set<ViolationKey> = []

  func evaluate(
    config: Config,
    now: UInt64,
    processes: [ProcessInfo],
    pidFilters: [Int: PIDFilter]
  ) -> DecisionOutput {
    var tracks: [TrackEvent] = []
    var effects: [EffectEvent] = []
    var matchedAny = false

    let needsTreeRootLookup = config.onlyTreeRoots
    let processByPID: [Int32: ProcessInfo] =
      needsTreeRootLookup
      ? Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
      : [:]
    var seenViolations: Set<ViolationKey> = []
    var warningActive: Set<ViolationKey> = []

    for process in processes {
      for (ruleIndex, rule) in config.rules.enumerated() {
        if let filter = pidFilters[ruleIndex], !filter.contains(process: process) {
          continue
        }
        if !processMatches(ruleProcess: rule.process, process: process) {
          continue
        }
        if needsTreeRootLookup,
          !isTreeRootForRule(ruleProcess: rule.process, process: process, processByPID: processByPID)
        {
          continue
        }
        if rule.action == .kill, isAllProcessRule(rule.process) {
          continue
        }

        matchedAny = true
        let key = ViolationKey(ruleIndex: ruleIndex, pid: process.pid)
        let current = currentMetricValue(metric: rule.metric, process: process)
        let status: TrackStatus = current >= rule.threshold ? .violating : .ok
        let processLabel = ruleProcessLabel(rule.process)

        if !isAllProcessRule(rule.process) {
          tracks.append(
            TrackEvent(
              ruleProcess: processLabel,
              pid: process.pid,
              metric: rule.metric,
              value: current,
              threshold: rule.threshold,
              forSeconds: rule.forSeconds,
              status: status
            )
          )
        }

        if isWarningActive(
          warningThreshold: config.warningThreshold,
          threshold: rule.threshold,
          current: current
        ) {
          warningActive.insert(key)
          if !warned.contains(key) {
            effects.append(
              .warning(
                message: warningMessage(
                  processLabel: processLabel,
                  warningThreshold: config.warningThreshold,
                  rule: rule,
                  process: process,
                  current: current
                )
              )
            )
            warned.insert(key)
          }
        }

        if current < rule.threshold {
          violations.removeValue(forKey: key)
          continue
        }

        seenViolations.insert(key)

        var violation = violations[key] ?? ViolationState(firstViolationAt: now, lastActionAt: 0)

        let waitFor = rule.forSeconds ?? 0
        if saturatingSubtract(now, violation.firstViolationAt) < waitFor {
          violations[key] = violation
          continue
        }

        let cooldown = rule.cooldownSeconds ?? defaultCooldown(for: rule.action)
        if cooldown > 0,
          violation.lastActionAt > 0,
          saturatingSubtract(now, violation.lastActionAt) < cooldown
        {
          violations[key] = violation
          continue
        }

        let message = actionMessage(processLabel: processLabel, rule: rule, process: process, current: current)
        switch rule.action {
        case .notify:
          effects.append(.notify(message: message))
        case .kill:
          effects.append(
            .kill(
              pid: process.pid,
              signal: rule.signal ?? .term,
              processName: process.name,
              expectedIdentity: signalIdentity(for: process),
              message: message,
              notifyUser: config.notifyOnKill
            )
          )
        }

        violation.lastActionAt = now
        violations[key] = violation
      }
    }

    violations = violations.filter { seenViolations.contains($0.key) }
    warned = warned.filter { warningActive.contains($0) }

    return DecisionOutput(tracks: tracks, effects: effects, matchedAny: matchedAny)
  }
}

private func processMatches(ruleProcess: String?, process: ProcessInfo) -> Bool {
  guard let ruleName = normalizedProcessFilter(ruleProcess) else {
    return true
  }

  if ruleName.caseInsensitiveCompare(process.name) == .orderedSame {
    return true
  }

  guard normalizedProcessFilter(process.name) == nil else {
    return false
  }

  let commandName = (process.command as NSString).lastPathComponent
  return ruleName.caseInsensitiveCompare(commandName) == .orderedSame
}

private func isTreeRootForRule(ruleProcess: String?, process: ProcessInfo, processByPID: [Int32: ProcessInfo]) -> Bool {
  if isAllProcessRule(ruleProcess) {
    if process.ppid <= 1 {
      return true
    }
    guard let parent = processByPID[process.ppid] else {
      return true
    }
    return parent.pid == 1
  }

  var parentPID = process.ppid
  var hops = 0

  while parentPID > 0, hops < 256 {
    guard let parent = processByPID[parentPID] else {
      return true
    }
    if processMatches(ruleProcess: ruleProcess, process: parent) {
      return false
    }
    parentPID = parent.ppid
    hops += 1
  }

  return true
}

private func isAllProcessRule(_ ruleProcess: String?) -> Bool {
  normalizedProcessFilter(ruleProcess) == nil
}

private func ruleProcessLabel(_ ruleProcess: String?) -> String {
  normalizedProcessFilter(ruleProcess) ?? "*"
}

private func currentMetricValue(metric: Metric, process: ProcessInfo) -> Double {
  switch metric {
  case .cpuPercent:
    return process.cpuPercent
  case .memoryMB:
    return Double(process.rssKB) / 1024.0
  case .runtimeSeconds:
    return Double(process.elapsedSeconds)
  }
}

private func signalIdentity(for process: ProcessInfo) -> ProcessSignalIdentity {
  let executableName: String?
  switch process.nameSource {
  case .executablePath:
    executableName = normalizedProcessFilter(process.name)
  case .bsdComm:
    executableName = nil
  }

  return ProcessSignalIdentity(startTime: process.startTime, executableName: executableName)
}

private func isWarningActive(warningThreshold: UInt8, threshold: Double, current: Double) -> Bool {
  if warningThreshold == 0 {
    return false
  }
  let warningLevel = threshold * (Double(warningThreshold) / 100.0)
  return current >= warningLevel && current < threshold
}

private func defaultCooldown(for action: ActionType) -> UInt64 {
  switch action {
  case .kill:
    return 0
  case .notify:
    return 60
  }
}

private func warningMessage(
  processLabel: String, warningThreshold: UInt8, rule: Rule, process: ProcessInfo, current: Double
) -> String {
  "\(processLabel) pid=\(process.pid) metric=\(rule.metric.rawValue) value=\(fixed2(current)) reached \(warningThreshold)% of threshold=\(fixed2(rule.threshold))"
}

private func actionMessage(processLabel: String, rule: Rule, process: ProcessInfo, current: Double) -> String {
  if let forSeconds = rule.forSeconds {
    return
      "\(processLabel) pid=\(process.pid) metric=\(rule.metric.rawValue) value=\(fixed2(current)) threshold=\(fixed2(rule.threshold)) persisted=\(forSeconds)s"
  }
  return
    "\(processLabel) pid=\(process.pid) metric=\(rule.metric.rawValue) value=\(fixed2(current)) threshold=\(fixed2(rule.threshold))"
}

private func saturatingSubtract(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
  lhs >= rhs ? (lhs - rhs) : 0
}
