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
        needsCommandPath = config.rules.contains { isConfiguredProcessRule($0.process) }
        hasPIDGlobRules = config.rules.contains {
            guard let pattern = $0.pidFileGlob?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return false
            }
            return !pattern.isEmpty
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
            if let forSeconds = track.forSeconds {
                logInfo(
                    "track \(track.ruleProcess) pid=\(track.pid) metric=\(track.metric.rawValue) value=\(fixed2(track.value)) threshold=\(fixed2(track.threshold)) for=\(forSeconds)s status=\(track.status.rawValue)"
                )
            } else {
                logInfo(
                    "track \(track.ruleProcess) pid=\(track.pid) metric=\(track.metric.rawValue) value=\(fixed2(track.value)) threshold=\(fixed2(track.threshold)) status=\(track.status.rawValue)"
                )
            }
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
        case let .warning(message):
            logWarn("warning \(message)")
            do {
                try notifier.notify(kind: .warning, message: message)
            } catch {
                logWarn("notification failed: \(error)")
            }
        case let .notify(message):
            do {
                try notifier.notify(kind: .monitor, message: message)
            } catch {
                logWarn("notification failed: \(error)")
            }
            logWarn("notified: \(message)")
        case let .kill(pid, signal, processName, message, notifyUser):
            try signalSender.send(pid: pid, signal: signal)
            logWarn("killed \(processName) (pid \(pid)) because \(message)")
            if notifyUser {
                do {
                    try notifier.notify(kind: .kill, message: message)
                } catch {
                    logWarn("notification failed: \(error)")
                }
            }
        }
    }

    private func logInfo(_ message: String) {
        guard verbose else {
            return
        }
        if let logHandler {
            logHandler(.info, message)
        } else {
            fputs("info: \(message)\n", stderr)
        }
    }

    private func logTickSeparator(tick: UInt64) {
        guard verbose else {
            return
        }
        if let logHandler {
            logHandler(.info, "----- tick \(tick) -----")
        } else {
            fputs("----- tick \(tick) -----\n", stderr)
        }
    }

    private func logWarn(_ message: String) {
        if let logHandler {
            logHandler(.warning, message)
        } else {
            fputs("warn: \(message)\n", stderr)
        }
    }
}

private func fixed2(_ value: Double) -> String {
    String(format: "%.2f", value)
}

private func isConfiguredProcessRule(_ process: String?) -> Bool {
    guard let process else {
        return false
    }
    return !process.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}
