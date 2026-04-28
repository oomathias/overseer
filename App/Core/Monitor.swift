import Foundation

enum MonitorLogLevel: String {
  case info
  case warning
}

typealias MonitorLogHandler = @Sendable (MonitorLogLevel, String) -> Void

final class MonitorRuntime {
  private let config: Config
  private let verbose: Bool
  private let sampler: ProcessSampler
  private let engine: DecisionEngine
  private let notifier: AppleNotifier
  private let signalSender: DarwinSignalSender
  private let pidResolver: PIDGlobResolver
  private let needsCommandPath: Bool
  private let hasPIDGlobRules: Bool
  private let logHandler: MonitorLogHandler?
  private var tickNumber: UInt64 = 0

  init(
    config: Config,
    verbose: Bool,
    sampler: ProcessSampler = ProcessSampler(),
    engine: DecisionEngine = DecisionEngine(),
    signalSender: DarwinSignalSender = DarwinSignalSender(),
    pidResolver: PIDGlobResolver = PIDGlobResolver(),
    logHandler: MonitorLogHandler? = nil
  ) {
    self.config = config
    self.verbose = verbose
    self.sampler = sampler
    self.engine = engine
    notifier = AppleNotifier()
    self.signalSender = signalSender
    self.pidResolver = pidResolver
    self.logHandler = logHandler
    needsCommandPath = config.rules.contains { normalizedProcessFilter($0.process) != nil }
    hasPIDGlobRules = config.rules.contains {
      normalizedProcessFilter($0.pidFileGlob) != nil
    }
  }

  func run() async throws {
    logInfo("starting \(appName) with \(config.rules.count) rule(s)")
    logInfo("poll interval: \(config.pollIntervalSeconds)s")

    while !Task.isCancelled {
      tickNumber &+= 1
      logTickSeparator(tick: tickNumber)
      try pollOnce()

      if config.pollIntervalSeconds > 0 {
        let sleepNS = UInt64(config.pollIntervalSeconds) * 1_000_000_000
        try await Task.sleep(nanoseconds: sleepNS)
      } else {
        await Task.yield()
      }
    }
  }

  private func pollOnce() throws {
    let processes = try sampler.snapshot(includeCommandPath: needsCommandPath)
    let filters = hasPIDGlobRules ? pidResolver.resolveFilters(rules: config.rules) : [:]
    let output = engine.evaluate(
      config: config,
      now: nowEpochSeconds(),
      processes: processes,
      pidFilters: filters
    )

    for track in output.tracks {
      var message =
        "track \(track.ruleProcess) pid=\(track.pid) metric=\(track.metric.rawValue) value=\(fixed2(track.value)) threshold=\(fixed2(track.threshold))"
      if let forSeconds = track.forSeconds {
        message += " for=\(forSeconds)s"
      }
      message += " status=\(track.status.rawValue)"
      logInfo(message)
    }

    for effect in output.effects {
      try apply(effect: effect)
    }

    if !output.matchedAny {
      logInfo("nothing matches configured processes")
    }
  }

  private func apply(effect: EffectEvent) throws {
    switch effect {
    case .warning(let message):
      logWarn("warning \(message)")
      notifyIfNeeded(kind: .warning, message: message)
    case .notify(let message):
      notifyIfNeeded(kind: .monitor, message: message)
      logWarn("notified: \(message)")
    case .kill(let pid, let signal, let processName, let expectedIdentity, let message, let notifyUser):
      try signalSender.send(pid: pid, signal: signal, expectedIdentity: expectedIdentity)
      logWarn("killed \(processName) (pid \(pid)) because \(message)")
      if notifyUser {
        notifyIfNeeded(kind: .kill, message: message)
      }
    }
  }

  private func notifyIfNeeded(kind: NotificationKind, message: String) {
    do {
      try notifier.notify(kind: kind, message: message)
    } catch {
      logWarn("notification failed: \(error)")
    }
  }

  private func log(level: MonitorLogLevel, message: String, requiresVerbose: Bool = false, raw: Bool = false) {
    if requiresVerbose && !verbose {
      return
    }
    if let logHandler {
      logHandler(level, message)
      return
    }

    let output = raw ? message : "\(level == .info ? "info: " : "warn: ")\(message)"
    fputs("\(output)\n", stderr)
  }

  private func logTickSeparator(tick: UInt64) {
    log(level: .info, message: "----- tick \(tick) -----", requiresVerbose: true, raw: true)
  }

  private func logWarn(_ message: String) {
    log(level: .warning, message: message)
  }

  private func logInfo(_ message: String) {
    log(level: .info, message: message, requiresVerbose: true)
  }

}
