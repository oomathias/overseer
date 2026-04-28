import Darwin
import Foundation

final class ServiceManager {
  private let commandRunner: CommandRunning
  private let verbose: Bool
  private let launchdUID: uid_t
  private let homeDirectory: String
  private let currentDirectory: () -> String
  private let executablePathResolver: () throws -> String

  init(
    commandRunner: CommandRunning,
    verbose: Bool,
    launchdUID: uid_t = getuid(),
    homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
    currentDirectory: @escaping () -> String = { FileManager.default.currentDirectoryPath },
    executablePathResolver: @escaping () throws -> String = { try resolveCurrentExecutablePath() }
  ) {
    self.commandRunner = commandRunner
    self.verbose = verbose
    self.launchdUID = launchdUID
    self.homeDirectory = homeDirectory
    self.currentDirectory = currentDirectory
    self.executablePathResolver = executablePathResolver
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
    let configAbsolutePath = try resolveAbsolutePath(configPath)
    let cwd = currentDirectory()

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
    try enableService()
    try runLaunchctlChecked(["bootstrap", launchdDomain(), launchdPlistPath()])
  }

  private func enableService() throws {
    try runLaunchctlChecked(["enable", launchdTarget()])
  }

  private func runLaunchctl(_ arguments: [String]) throws -> CommandOutput {
    try commandRunner.run(
      program: "/bin/launchctl",
      arguments: arguments,
      timeout: 10,
      maxOutputBytes: 1024 * 1024,
      environment: nil,
      stdoutHandler: nil,
      stderrHandler: nil
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
    try executablePathResolver()
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
