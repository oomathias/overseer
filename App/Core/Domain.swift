import Foundation

let appName = "overseer"
let serviceLabel = "io.m7b.overseer.agent"
let defaultConfigPath = "~/.config/overseer/config.json"

enum Metric: String, Decodable {
  case cpuPercent = "cpu_percent"
  case memoryMB = "memory_mb"
  case runtimeSeconds = "runtime_seconds"
}

enum ActionType: String, Decodable {
  case kill
  case notify
}

enum KillSignal: String, Decodable {
  case term
  case kill
  case int
}

enum NotificationKind {
  case warning
  case kill
  case monitor
}

struct Rule: Decodable {
  let process: String?
  let pidFileGlob: String?
  let metric: Metric
  let threshold: Double
  let forSeconds: UInt64?
  let action: ActionType
  let signal: KillSignal?
  let cooldownSeconds: UInt64?

  enum CodingKeys: String, CodingKey {
    case process
    case pidFileGlob = "pid_file_glob"
    case metric
    case threshold
    case forSeconds = "for_seconds"
    case action
    case signal
    case cooldownSeconds = "cooldown_seconds"
  }
}

struct Config: Decodable {
  let pollIntervalSeconds: UInt64
  let onlyTreeRoots: Bool
  let notifyOnKill: Bool
  let warningThreshold: UInt8
  let rules: [Rule]

  enum CodingKeys: String, CodingKey {
    case pollIntervalSeconds = "poll_interval_seconds"
    case onlyTreeRoots = "only_tree_roots"
    case notifyOnKill = "notify_on_kill"
    case warningThreshold = "warning_threshold"
    case rules
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    pollIntervalSeconds = try container.decodeIfPresent(UInt64.self, forKey: .pollIntervalSeconds) ?? 5
    onlyTreeRoots = try container.decodeIfPresent(Bool.self, forKey: .onlyTreeRoots) ?? true
    notifyOnKill = try container.decodeIfPresent(Bool.self, forKey: .notifyOnKill) ?? true
    warningThreshold = try container.decodeIfPresent(UInt8.self, forKey: .warningThreshold) ?? 0
    rules = try container.decode([Rule].self, forKey: .rules)
  }

  func validate() throws {
    if rules.isEmpty {
      throw OverseerError.invalidConfig("config has no rules")
    }
    if warningThreshold > 99 {
      throw OverseerError.invalidConfig("warning_threshold must be between 0 and 99")
    }
    for (index, rule) in rules.enumerated() {
      if rule.threshold < 0 {
        throw OverseerError.invalidConfig("rule \(index) has negative threshold")
      }
      if let pidFileGlob = normalizedProcessFilter(rule.pidFileGlob),
        hasUnresolvedUserPath(pidFileGlob)
      {
        throw OverseerError.invalidConfig("rule \(index) has unexpandable pid_file_glob \(pidFileGlob)")
      }
    }
  }
}

struct ProcessInfo {
  let pid: Int32
  let ppid: Int32
  let name: String
  let command: String
  let cpuPercent: Double
  let rssKB: UInt64
  let elapsedSeconds: UInt64
}

enum TrackStatus: String {
  case ok
  case violating
}

struct TrackEvent {
  let ruleProcess: String
  let pid: Int32
  let metric: Metric
  let value: Double
  let threshold: Double
  let forSeconds: UInt64?
  let status: TrackStatus
}

enum EffectEvent {
  case warning(message: String)
  case notify(message: String)
  case kill(pid: Int32, signal: KillSignal, processName: String, message: String, notifyUser: Bool)
}

struct DecisionOutput {
  let tracks: [TrackEvent]
  let effects: [EffectEvent]
  let matchedAny: Bool
}

func normalizedProcessFilter(_ value: String?) -> String? {
  guard let value else {
    return nil
  }

  let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
  if trimmed.isEmpty {
    return nil
  }

  return trimmed
}

func fixed2(_ value: Double) -> String {
  String(format: "%.2f", value)
}
