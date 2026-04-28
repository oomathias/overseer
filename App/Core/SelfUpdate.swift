import Foundation

struct UpdateResult {
  let installDir: String
}

final class SelfUpdateManager {
  typealias DownloadScript = (_ sourceURL: URL, _ destinationURL: URL) throws -> Void

  static let installerURL = URL(string: "https://raw.githubusercontent.com/oomathias/overseer/main/install")!
  private static let installerPATH = "/usr/bin:/bin:/usr/sbin:/sbin"

  private let commandRunner: CommandRunner
  private let environment: [String: String]
  private let temporaryDirectory: URL
  private let executablePathResolver: () throws -> String
  private let downloadScript: DownloadScript

  init(
    commandRunner: CommandRunner = CommandRunner(),
    environment: [String: String] = Foundation.ProcessInfo.processInfo.environment,
    temporaryDirectory: URL = FileManager.default.temporaryDirectory,
    executablePathResolver: @escaping () throws -> String = { try resolveCurrentExecutablePath() },
    downloadScript: @escaping DownloadScript = SelfUpdateManager.defaultDownloadScript
  ) {
    self.commandRunner = commandRunner
    self.environment = environment
    self.temporaryDirectory = temporaryDirectory
    self.executablePathResolver = executablePathResolver
    self.downloadScript = downloadScript
  }

  func updateToLatest() throws -> UpdateResult {
    try updateToLatest(stdoutHandler: nil, stderrHandler: nil)
  }

  func updateToLatest(
    stdoutHandler: ((Data) -> Void)?,
    stderrHandler: ((Data) -> Void)?
  ) throws -> UpdateResult {
    let installDir = try currentInstallDirectory()
    let workDir = temporaryDirectory.appendingPathComponent("overseer-update-\(UUID().uuidString)", isDirectory: true)

    do {
      try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    } catch {
      throw OverseerError.io("failed to create temporary update directory: \(error.localizedDescription)")
    }
    defer {
      try? FileManager.default.removeItem(at: workDir)
    }

    let scriptURL = workDir.appendingPathComponent("install")
    try downloadScript(Self.installerURL, scriptURL)

    var installerEnvironment = Self.sanitizedInstallerEnvironment(from: environment)
    installerEnvironment["OVERSEER_INSTALL_DIR"] = installDir

    let output = try commandRunner.run(
      program: "/bin/bash",
      arguments: [scriptURL.path],
      timeout: 300,
      maxOutputBytes: 1024 * 1024,
      environment: installerEnvironment,
      stdoutHandler: stdoutHandler,
      stderrHandler: stderrHandler
    )

    if output.timedOut {
      throw OverseerError.commandTimedOut("update timed out")
    }

    guard output.exitCode == 0 else {
      let stderr = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
      let stdout = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
      let message = stderr.isEmpty ? stdout : stderr
      let detail = message.isEmpty ? "installer exited with status \(output.exitCode)" : message
      throw OverseerError.commandFailed("update failed: \(detail)")
    }

    return UpdateResult(installDir: installDir)
  }

  func currentInstallDirectory() throws -> String {
    let executablePath = try executablePathResolver()
    return try Self.installDirectory(forExecutablePath: executablePath)
  }

  static func installDirectory(forExecutablePath executablePath: String) throws -> String {
    let absolutePath = try resolveAbsolutePath(executablePath)
    let installDir = (absolutePath as NSString).deletingLastPathComponent
    guard !installDir.isEmpty else {
      throw OverseerError.system("failed to determine install directory for \(absolutePath)")
    }
    return installDir
  }

  private static func defaultDownloadScript(from sourceURL: URL, to destinationURL: URL) throws {
    guard sourceURL.scheme == "https" else {
      throw OverseerError.system("refusing non-https install script URL: \(sourceURL.absoluteString)")
    }

    let scriptData: Data
    do {
      scriptData = try Data(contentsOf: sourceURL)
    } catch {
      throw OverseerError.system("failed to download install script: \(error.localizedDescription)")
    }

    guard !scriptData.isEmpty else {
      throw OverseerError.system("downloaded install script was empty")
    }

    do {
      try scriptData.write(to: destinationURL, options: [.atomic])
    } catch {
      throw OverseerError.io("failed to write install script: \(error.localizedDescription)")
    }
  }

  private static func sanitizedInstallerEnvironment(from environment: [String: String]) -> [String: String] {
    var sanitized: [String: String] = [:]
    sanitized["PATH"] = Self.installerPATH

    if let home = environment["HOME"] {
      sanitized["HOME"] = home
    }
    if let tmpdir = environment["TMPDIR"] {
      sanitized["TMPDIR"] = tmpdir
    }

    return sanitized
  }
}
