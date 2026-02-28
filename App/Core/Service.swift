import Foundation
import Darwin

final class ServiceManager {
    private let commandRunner: CommandRunner
    private let verbose: Bool

    init(commandRunner: CommandRunner, verbose: Bool) {
        self.commandRunner = commandRunner
        self.verbose = verbose
    }

    func install(configPath: String) throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let launchAgentsDir = (home as NSString).appendingPathComponent("Library/LaunchAgents")
        let logsDir = (home as NSString).appendingPathComponent("Library/Logs")
        try FileManager.default.createDirectory(atPath: launchAgentsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: logsDir, withIntermediateDirectories: true)

        let plistPath = (launchAgentsDir as NSString).appendingPathComponent("\(serviceLabel).plist")
        let stdoutLog = (logsDir as NSString).appendingPathComponent("overseer.log")
        let stderrLog = (logsDir as NSString).appendingPathComponent("overseer.err.log")

        let executablePath = try resolveServiceExecutablePath()
        let configAbsolutePath = resolveAbsolutePath(configPath)
        let cwd = FileManager.default.currentDirectoryPath

        try writeLaunchAgentPlist(
            plistPath: plistPath,
            executablePath: executablePath,
            configPath: configAbsolutePath,
            workingDirectory: cwd,
            stdoutLog: stdoutLog,
            stderrLog: stderrLog
        )

        let domain = launchdDomain()
        let target = launchdTarget()

        tryBootout(target: target)
        try runLaunchctlChecked(["bootstrap", domain, plistPath])
        try runLaunchctlChecked(["kickstart", "-k", target])
    }

    func uninstall() throws {
        let target = launchdTarget()
        let plistPath = launchdPlistPath()

        tryBootout(target: target)
        if FileManager.default.fileExists(atPath: plistPath) {
            try FileManager.default.removeItem(atPath: plistPath)
        }
    }

    func start() throws {
        let domain = launchdDomain()
        let target = launchdTarget()
        let firstTry = try runLaunchctl(["kickstart", "-k", target])

        if firstTry.timedOut || firstTry.exitCode != 0 {
            try runLaunchctlChecked(["bootstrap", domain, launchdPlistPath()])
            try runLaunchctlChecked(["kickstart", "-k", target])
        }
    }

    func stop() throws {
        try runLaunchctlChecked(["bootout", launchdTarget()])
    }

    func restart() throws {
        let domain = launchdDomain()
        let target = launchdTarget()
        let plistPath = launchdPlistPath()

        tryBootout(target: target)
        try runLaunchctlChecked(["bootstrap", domain, plistPath])
        try runLaunchctlChecked(["kickstart", "-k", target])
    }

    func status() throws -> String {
        let out = try runLaunchctl(["print", launchdTarget()])
        if out.timedOut {
            throw OverseerError.commandTimedOut("launchctl print timed out")
        }
        if out.exitCode == 0 {
            return out.stdout.trimmingCharacters(in: .newlines)
        }
        return "service \(serviceLabel) is not running"
    }

    private func runLaunchctl(_ arguments: [String]) throws -> CommandOutput {
        try commandRunner.run(
            program: "/bin/launchctl",
            arguments: arguments,
            timeout: 10,
            maxOutputBytes: 1024 * 1024
        )
    }

    private func runLaunchctlChecked(_ arguments: [String]) throws {
        let output = try runLaunchctl(arguments)
        if output.timedOut {
            throw OverseerError.commandTimedOut("launchctl \(arguments.first ?? "") timed out")
        }
        if output.exitCode != 0 {
            let errorText = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw OverseerError.commandFailed("launchctl \(arguments.first ?? "") failed: \(errorText)")
        }
        if verbose {
            let trimmed = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                print(trimmed)
            }
        }
    }

    private func tryBootout(target: String) {
        _ = try? runLaunchctl(["bootout", target])
    }

    private func launchdDomain() -> String {
        "gui/\(getuid())"
    }

    private func launchdTarget() -> String {
        "gui/\(getuid())/\(serviceLabel)"
    }

    private func launchdPlistPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent("Library/LaunchAgents/\(serviceLabel).plist")
    }

    private func resolveServiceExecutablePath() throws -> String {
        try resolveBundledExecutableForService()
    }

    private func writeLaunchAgentPlist(
        plistPath: String,
        executablePath: String,
        configPath: String,
        workingDirectory: String,
        stdoutLog: String,
        stderrLog: String
    ) throws {
        let plist: [String: Any] = [
            "Label": serviceLabel,
            "ProgramArguments": [executablePath, "--config", configPath],
            "WorkingDirectory": workingDirectory,
            "RunAtLoad": true,
            "KeepAlive": true,
            "StandardOutPath": stdoutLog,
            "StandardErrorPath": stderrLog,
        ]

        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: plistPath), options: .atomic)
    }
}
