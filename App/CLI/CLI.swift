import Foundation
import Darwin
import Dispatch

@main
struct OverseerCLI {
    static func main() async {
        do {
            try await run(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch let error as OverseerError {
            if case .handled = error {
                return
            }
            fputs("error: \(error.description)\n", stderr)
            if case .invalidArguments = error {
                exit(64)
            }
            exit(1)
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func run(arguments: [String]) async throws {
        if arguments.isEmpty {
            printUsage()
            return
        }

        if let first = arguments.first, first.hasPrefix("-") {
            let options = try parseOptions(arguments)
            try await runMonitor(options: options)
            return
        }

        let command = arguments[0]
        let remaining = Array(arguments.dropFirst())

        switch command {
        case "help", "-h", "--help":
            printUsage()
        case "version", "-v", "--version":
            print("\(appName) \(appVersion)")
        case "monitor":
            let options = try parseOptions(remaining)
            try await runMonitor(options: options)
        case "validate":
            let options = try parseOptions(remaining)
            try runValidate(options: options)
        case "service":
            try runService(arguments: remaining)
        default:
            throw OverseerError.invalidArguments("unknown command '\(command)'")
        }
    }

    private static func runValidate(options: CLIOptions) throws {
        let config = try loadConfig(from: options.configPath)
        print("config ok")
        print("rules: \(config.rules.count)")
        print("poll_interval_seconds: \(config.pollIntervalSeconds)")
        print("only_tree_roots: \(config.onlyTreeRoots ? "true" : "false")")
        print("warning_threshold: \(config.warningThreshold)")
        print("notify_on_kill: \(config.notifyOnKill ? "true" : "false")")
    }

    private static func runMonitor(options: CLIOptions) async throws {
        let stderrIsTTY = isatty(fileno(stderr)) == 1
        let terminalSupportsLiveView = stderrIsTTY && supportsLiveTerminalOutput()
        let logRenderer = CLILogRenderer(
            useColor: stderrIsTTY,
            liveTickView: options.verbose && options.liveTickView && terminalSupportsLiveView
        )

        let config = try loadConfig(from: options.configPath)
        let runtime = MonitorRuntime(
            config: config,
            verbose: options.verbose,
            logHandler: { level, message in
                logRenderer.log(level: level, message: message)
            }
        )

        let monitorTask = Task {
            try await runtime.run()
        }

        let signalTrap = SignalTrap(signals: [SIGINT, SIGTERM]) {
            monitorTask.cancel()
        }
        defer { signalTrap.invalidate() }

        do {
            try await monitorTask.value
        } catch is CancellationError {
            if options.verbose {
                logRenderer.log(level: .info, message: "monitor stopped")
            }
        }
    }

    private static func supportsLiveTerminalOutput() -> Bool {
        let env = Foundation.ProcessInfo.processInfo.environment
        guard let term = env["TERM"], !term.isEmpty, term != "dumb" else {
            return false
        }
        if env["CI"] != nil {
            return false
        }
        return true
    }

    private static func runService(arguments: [String]) throws {
        guard let subcommand = arguments.first else {
            throw OverseerError.invalidArguments("service command requires a subcommand")
        }

        let options = try parseOptions(Array(arguments.dropFirst()))
        let manager = ServiceManager(commandRunner: CommandRunner(), verbose: options.verbose)

        switch subcommand {
        case "install":
            try manager.install(configPath: options.configPath)
            print("service installed: \(serviceLabel)")
        case "uninstall":
            try manager.uninstall()
            print("service uninstalled: \(serviceLabel)")
        case "start":
            try manager.start()
            print("service started: \(serviceLabel)")
        case "stop":
            try manager.stop()
            print("service stopped: \(serviceLabel)")
        case "restart":
            try manager.restart()
            print("service restarted: \(serviceLabel)")
        case "status":
            print(try manager.status())
        default:
            throw OverseerError.invalidArguments("unknown service subcommand '\(subcommand)'")
        }
    }

    private static func parseOptions(_ arguments: [String]) throws -> CLIOptions {
        var configPath = defaultConfigPath
        var verbose = true
        var liveTickView = true

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--config":
                let valueIndex = index + 1
                guard valueIndex < arguments.count else {
                    throw OverseerError.invalidArguments("--config requires a path")
                }
                configPath = arguments[valueIndex]
                index = valueIndex + 1
            case "--verbose":
                verbose = true
                index += 1
            case "--quiet":
                verbose = false
                index += 1
            case "--live":
                liveTickView = true
                index += 1
            case "--no-live":
                liveTickView = false
                index += 1
            case "-h", "--help":
                printUsage()
                throw OverseerError.handled
            default:
                throw OverseerError.invalidArguments("unknown argument '\(argument)'")
            }
        }

        return CLIOptions(configPath: configPath, verbose: verbose, liveTickView: liveTickView)
    }

    private static func printUsage() {
        let usage = """
        overseer \(appVersion)

        Usage:
          overseer monitor [--config PATH] [--verbose|--quiet] [--live|--no-live]
          overseer validate [--config PATH]
          overseer service <install|uninstall|start|stop|restart|status> [--config PATH] [--verbose|--quiet] [--live|--no-live]
          overseer version

        Compatibility mode:
          overseer --config PATH [--verbose|--quiet] [--live|--no-live]

        Defaults:
          --config \(defaultConfigPath)
          --verbose enabled
          --live enabled
        """
        print(usage)
    }
}

private struct CLIOptions {
    let configPath: String
    let verbose: Bool
    let liveTickView: Bool
}

private final class SignalTrap {
    private var sources: [DispatchSourceSignal] = []

    init(signals: [Int32], handler: @escaping @Sendable () -> Void) {
        for signalNumber in signals {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global(qos: .userInitiated))
            source.setEventHandler(handler: handler)
            source.resume()
            sources.append(source)
        }
    }

    func invalidate() {
        for source in sources {
            source.cancel()
        }
        sources.removeAll()
    }
}

private final class CLILogRenderer {
    private let useColor: Bool
    private let liveTickView: Bool
    private var preludeLines: [String] = []
    private var currentTick: UInt64?
    private var tickLines: [(MonitorLogLevel, String)] = []
    private var startupRuleCount: String?
    private var startupPollInterval: String?

    init(useColor: Bool, liveTickView: Bool) {
        self.useColor = useColor
        self.liveTickView = liveTickView
    }

    func log(level: MonitorLogLevel, message: String) {
        if let tick = parseTick(message) {
            currentTick = tick
            tickLines.removeAll(keepingCapacity: true)
            if liveTickView {
                renderLiveView()
            }
            return
        }

        if liveTickView {
            if currentTick == nil {
                if level == .info, captureStartupInfo(message: message) {
                    renderLiveView()
                    return
                }
                let formatted = formatLine(level: level, message: message, compact: false)
                if preludeLines.last != formatted {
                    preludeLines.append(formatted)
                }
            } else {
                tickLines.append((level, message))
            }
            renderLiveView()
            return
        }

        writeLine(formatLine(level: level, message: message, compact: true))
    }

    private func renderLiveView() {
        var lines: [String] = []
        lines.append(style("Overseer Monitor", color: .cyan, bold: true))

        if !preludeLines.isEmpty {
            for line in preludeLines {
                lines.append(line)
            }
            lines.append("")
        }

        if tickLines.isEmpty {
            lines.append(style("waiting for events...", color: .dim))
            write("\u{001B}[2J\u{001B}[H")
            for line in lines {
                writeLine(line)
            }
            return
        }

        let parsedTickLines = tickLines.map { (level: $0.0, message: $0.1, track: parseTrackLine($0.1)) }
        let trackEntries = parsedTickLines.compactMap { $0.track }
        let nonTrackEntries = parsedTickLines.filter { $0.track == nil }.map { ($0.level, $0.message) }

        let violating = trackEntries
            .filter { $0.status == "violating" }
            .sorted { $0.ratio > $1.ratio }
        let ok = trackEntries
            .filter { $0.status == "ok" }
            .sorted { $0.ratio > $1.ratio }

        let hotDisplay = violating.prefix(12)
        let healthyProcesses = healthyProcesses(from: ok)
        let startupPrefix = startupSummaryLine().map { "\($0)  |  " } ?? ""
        let summary = "\(startupPrefix)tracks: \(trackEntries.count)  hot: \(violating.count)  ok: \(ok.count)  pids: \(healthyProcesses.count)  logs: \(nonTrackEntries.count)"
        lines.append(style(summary, color: .dim))

        var detailLines: [String] = []
        for (level, message) in nonTrackEntries {
            detailLines.append(formatLine(level: level, message: message, compact: false))
        }

        if !violating.isEmpty {
            detailLines.append(style("Hot (showing \(hotDisplay.count)/\(violating.count))", color: .yellow, bold: true))
            for item in hotDisplay {
                detailLines.append(formatTrack(item, hot: true))
            }
            if violating.count > hotDisplay.count {
                detailLines.append(style("... \(violating.count - hotDisplay.count) hot entries hidden", color: .dim))
            }
        }

        if !healthyProcesses.isEmpty {
            let maxOkLines = 12
            let shown = min(healthyProcesses.count, maxOkLines)
            detailLines.append(style("Healthy pids (showing \(shown)/\(healthyProcesses.count))", color: .green, bold: true))
            for item in healthyProcesses.prefix(maxOkLines) {
                detailLines.append(formatProcessHealth(item, hot: false))
            }
            if healthyProcesses.count > maxOkLines {
                detailLines.append(style("... \(healthyProcesses.count - maxOkLines) healthy pids hidden", color: .dim))
            }
        }

        let totalRows = max(10, terminalRows())
        let availableRows = max(1, totalRows - lines.count)
        if detailLines.count > availableRows {
            let keep = max(1, availableRows - 1)
            let hidden = detailLines.count - keep
            detailLines = Array(detailLines.prefix(keep))
            detailLines.append(style("... \(hidden) lines hidden", color: .dim))
        }

        lines.append(contentsOf: detailLines)

        write("\u{001B}[2J\u{001B}[H")
        for line in lines {
            writeLine(line)
        }
    }

    private func formatLine(level: MonitorLogLevel, message: String, compact: Bool) -> String {
        switch level {
        case .info:
            return formatInfo(message: message, compact: compact)
        case .warning:
            return formatWarning(message: message, compact: compact)
        }
    }

    private func formatInfo(message: String, compact: Bool) -> String {
        if message.hasPrefix("track ") {
            if let track = parseTrackLine(message), !compact {
                return formatTrack(track, hot: track.status == "violating")
            }
            if message.contains("status=violating") {
                return styledPrefix("HOT", color: .yellow, compact: compact) + message
            }
            if message.contains("status=ok") {
                return styledPrefix("OK ", color: .green, compact: compact) + message
            }
            return styledPrefix("TRK", color: .cyan, compact: compact) + message
        }

        if message.hasPrefix("nothing matches") {
            return styledPrefix("IDLE", color: .dim, compact: compact) + style(message, color: .dim)
        }

        return styledPrefix("INFO", color: .blue, compact: compact) + message
    }

    private func formatWarning(message: String, compact: Bool) -> String {
        if message.hasPrefix("killed ") {
            return styledPrefix("KILL", color: .red, compact: compact) + message
        }
        if message.hasPrefix("warning ") {
            return styledPrefix("WARN", color: .yellow, compact: compact) + message
        }
        if message.hasPrefix("notified:") {
            return styledPrefix("NOTE", color: .magenta, compact: compact) + message
        }
        return styledPrefix("WARN", color: .red, compact: compact) + message
    }

    private func styledPrefix(_ text: String, color: ANSIColor, compact: Bool) -> String {
        let bracketed = compact ? "[\(text)] " : "[\(text)] "
        return style(bracketed, color: color, bold: true)
    }

    private func parseTick(_ message: String) -> UInt64? {
        let prefix = "----- tick "
        let suffix = " -----"
        guard message.hasPrefix(prefix), message.hasSuffix(suffix) else {
            return nil
        }
        let start = message.index(message.startIndex, offsetBy: prefix.count)
        let end = message.index(message.endIndex, offsetBy: -suffix.count)
        let number = message[start..<end]
        return UInt64(number)
    }

    private func captureStartupInfo(message: String) -> Bool {
        let startPrefix = "starting overseer with "
        let startSuffix = " rule(s)"
        if message.hasPrefix(startPrefix), message.hasSuffix(startSuffix) {
            let start = message.index(message.startIndex, offsetBy: startPrefix.count)
            let end = message.index(message.endIndex, offsetBy: -startSuffix.count)
            startupRuleCount = String(message[start..<end])
            return true
        }

        let pollPrefix = "poll interval: "
        if message.hasPrefix(pollPrefix) {
            startupPollInterval = String(message.dropFirst(pollPrefix.count))
            return true
        }

        return false
    }

    private func startupSummaryLine() -> String? {
        if let startupRuleCount, let startupPollInterval {
            return "rules: \(startupRuleCount)  poll: \(startupPollInterval)"
        }
        if let startupRuleCount {
            return "rules: \(startupRuleCount)"
        }
        if let startupPollInterval {
            return "poll: \(startupPollInterval)"
        }
        return nil
    }

    private func parseTrackLine(_ message: String) -> TrackLine? {
        let tokens = message.split(separator: " ")
        guard tokens.count >= 3, tokens[0] == "track" else {
            return nil
        }

        let processName = String(tokens[1])

        var pid: Int32?
        var metric: String?
        var value: Double?
        var threshold: Double?
        var forSeconds: String?
        var status: String?

        for token in tokens.dropFirst(2) {
            let parts = token.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else {
                continue
            }
            let key = parts[0]
            let rawValue = parts[1]

            switch key {
            case "pid":
                pid = Int32(rawValue)
            case "metric":
                metric = String(rawValue)
            case "value":
                value = Double(rawValue)
            case "threshold":
                threshold = Double(rawValue)
            case "for":
                forSeconds = String(rawValue)
            case "status":
                status = String(rawValue)
            default:
                continue
            }
        }

        guard
            let pid,
            let metric,
            let value,
            let threshold,
            let status
        else {
            return nil
        }

        let ratio = threshold > 0 ? (value / threshold) : 0
        return TrackLine(
            processName: processName,
            pid: pid,
            metric: metric,
            value: value,
            threshold: threshold,
            forSeconds: forSeconds,
            status: status,
            ratio: ratio
        )
    }

    private func healthyProcesses(from tracks: [TrackLine]) -> [ProcessHealth] {
        var tracksByPID: [Int32: [TrackLine]] = [:]

        for track in tracks {
            tracksByPID[track.pid, default: []].append(track)
        }

        var result: [ProcessHealth] = []
        result.reserveCapacity(tracksByPID.count)

        for pidTracks in tracksByPID.values {
            guard let primary = selectPrimaryTrack(pidTracks) else {
                continue
            }
            result.append(ProcessHealth(track: primary, matchedRules: pidTracks.count))
        }

        return result.sorted { lhs, rhs in
            if lhs.track.pid != rhs.track.pid {
                return lhs.track.pid > rhs.track.pid
            }
            return lhs.track.ratio > rhs.track.ratio
        }
    }

    private func selectPrimaryTrack(_ tracks: [TrackLine]) -> TrackLine? {
        tracks.max { lhs, rhs in
            let lhsSpecificity = processSpecificity(lhs.processName)
            let rhsSpecificity = processSpecificity(rhs.processName)
            if lhsSpecificity != rhsSpecificity {
                return lhsSpecificity < rhsSpecificity
            }
            return lhs.ratio < rhs.ratio
        }
    }

    private func processSpecificity(_ processName: String) -> Int {
        let trimmed = processName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "*" {
            return 0
        }
        return trimmed.count
    }

    private func formatTrack(_ track: TrackLine, hot: Bool) -> String {
        let prefix = hot ? styledPrefix("HOT", color: .yellow, compact: false) : styledPrefix("OK ", color: .green, compact: false)
        let valueText = String(format: "%.2f", track.value)
        let thresholdText = String(format: "%.2f", track.threshold)
        let ratioText = String(format: "%3.0f%%", track.threshold > 0 ? (track.value / track.threshold) * 100.0 : 0.0)
        if let forSeconds = track.forSeconds {
            return "\(prefix)\(track.processName) pid=\(track.pid) \(track.metric) \(valueText)/\(thresholdText) \(ratioText) for=\(forSeconds)"
        }
        return "\(prefix)\(track.processName) pid=\(track.pid) \(track.metric) \(valueText)/\(thresholdText) \(ratioText)"
    }

    private func formatProcessHealth(_ process: ProcessHealth, hot: Bool) -> String {
        var line = formatTrack(process.track, hot: hot)
        if process.matchedRules > 1 {
            line += style("  rules=\(process.matchedRules)", color: .dim)
        }
        return line
    }

    private func style(_ text: String, color: ANSIColor? = nil, bold: Bool = false) -> String {
        guard useColor else {
            return text
        }

        var codes: [String] = []
        if bold {
            codes.append("1")
        }
        if let color {
            codes.append(color.rawValue)
        }
        if codes.isEmpty {
            return text
        }
        return "\u{001B}[\(codes.joined(separator: ";"))m\(text)\u{001B}[0m"
    }

    private func write(_ text: String) {
        fputs(text, stderr)
    }

    private func writeLine(_ text: String) {
        fputs("\(text)\n", stderr)
    }

    private func terminalRows() -> Int {
        var size = winsize()
        if ioctl(fileno(stderr), TIOCGWINSZ, &size) == 0, size.ws_row > 0 {
            return Int(size.ws_row)
        }
        return 24
    }
}

private struct TrackLine {
    let processName: String
    let pid: Int32
    let metric: String
    let value: Double
    let threshold: Double
    let forSeconds: String?
    let status: String
    let ratio: Double
}

private struct ProcessHealth {
    let track: TrackLine
    let matchedRules: Int
}

private enum ANSIColor: String {
    case red = "31"
    case green = "32"
    case yellow = "33"
    case blue = "34"
    case magenta = "35"
    case cyan = "36"
    case dim = "2"
}
