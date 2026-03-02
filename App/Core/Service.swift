import Foundation
import Darwin

final class ServiceManager {
    private let commandRunner: CommandRunner
    private let verbose: Bool
    private let launchdUID: uid_t
    private let homeDirectory: String

    init(commandRunner: CommandRunner, verbose: Bool) {
        self.commandRunner = commandRunner
        self.verbose = verbose
        launchdUID = getuid()
        homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
    }

    private func launchdPath(_ relativePath: String) -> String {
        (homeDirectory as NSString).appendingPathComponent(relativePath)
    }

    func install(configPath: String) throws {
        let launchAgentsDir = launchdPath("Library/LaunchAgents")
        let logsDir = launchdPath("Library/Logs")
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

        tryBootout(target: launchdTarget())
        try bootstrapService()
    }

    func uninstall() throws {
        let plistPath = launchdPlistPath()

        tryBootout(target: launchdTarget())
        if FileManager.default.fileExists(atPath: plistPath) {
            try FileManager.default.removeItem(atPath: plistPath)
        }
    }

    func start() throws {
        let firstTry = try runLaunchctl(["kickstart", launchdTarget()])

        if firstTry.timedOut || firstTry.exitCode != 0 {
            try bootstrapService()
        }
    }

    func stop() throws {
        try runLaunchctlChecked(["bootout", launchdTarget()])
    }

    func restart() throws {
        tryBootout(target: launchdTarget())
        try bootstrapService()
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

    private func bootstrapService() throws {
        try runLaunchctlChecked(["bootstrap", launchdDomain(), launchdPlistPath()])
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
        let subcommand = arguments.first ?? ""
        if output.timedOut {
            throw OverseerError.commandTimedOut("launchctl \(subcommand) timed out")
        }
        if output.exitCode != 0 {
            let errorText = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw OverseerError.commandFailed("launchctl \(subcommand) failed: \(errorText)")
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
        "gui/\(launchdUID)"
    }

    private func launchdTarget() -> String {
        "\(launchdDomain())/\(serviceLabel)"
    }

    private func launchdPlistPath() -> String {
        (launchdPath("Library/LaunchAgents") as NSString).appendingPathComponent("\(serviceLabel).plist")
    }

    private func resolveServiceExecutablePath() throws -> String {
        if let executablePath = Bundle.main.executablePath {
            return resolveAbsolutePath(executablePath)
        }

        if let firstArgument = CommandLine.arguments.first, !firstArgument.isEmpty {
            return resolveAbsolutePath(firstArgument)
        }

        throw OverseerError.system("failed to resolve executable path for launchd service")
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
            "ProgramArguments": [executablePath, "--config", configPath, "--quiet", "--no-live"],
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
