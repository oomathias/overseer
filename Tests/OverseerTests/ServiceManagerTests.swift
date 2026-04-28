import Foundation
import XCTest

@testable import overseer

final class ServiceManagerTests: XCTestCase {
  func testInstallEnablesLaunchdServiceBeforeBootstrap() throws {
    let homeDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("overseer-service-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: homeDirectory, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: homeDirectory)
    }

    let runner = RecordingCommandRunner()
    let manager = ServiceManager(
      commandRunner: runner,
      verbose: false,
      launchdUID: 501,
      homeDirectory: homeDirectory.path,
      currentDirectory: { "/Users/test" },
      executablePathResolver: { "/usr/local/bin/overseer" }
    )
    let configPath = "/Users/test/.config/overseer/config.json"
    let plistPath =
      homeDirectory
      .appendingPathComponent("Library/LaunchAgents/io.m7b.overseer.agent.plist").path

    try manager.install(configPath: configPath)

    XCTAssertEqual(runner.programs, ["/bin/launchctl", "/bin/launchctl", "/bin/launchctl"])
    XCTAssertEqual(
      runner.arguments,
      [
        ["bootout", "gui/501/io.m7b.overseer.agent"],
        ["enable", "gui/501/io.m7b.overseer.agent"],
        ["bootstrap", "gui/501", plistPath],
      ]
    )

    let plistData = try Data(contentsOf: URL(fileURLWithPath: plistPath))
    let plist = try XCTUnwrap(
      PropertyListSerialization.propertyList(from: plistData, options: [], format: nil)
        as? [String: Any]
    )
    XCTAssertEqual(
      plist["ProgramArguments"] as? [String],
      ["/usr/local/bin/overseer", "--config", configPath, "--quiet", "--no-live"]
    )
    XCTAssertEqual(plist["WorkingDirectory"] as? String, "/Users/test")
  }
}

private final class RecordingCommandRunner: CommandRunning {
  private(set) var programs: [String] = []
  private(set) var arguments: [[String]] = []

  func run(
    program: String,
    arguments: [String],
    timeout: TimeInterval,
    maxOutputBytes: Int,
    environment: [String: String]?,
    stdoutHandler: ((Data) -> Void)?,
    stderrHandler: ((Data) -> Void)?
  ) throws -> CommandOutput {
    programs.append(program)
    self.arguments.append(arguments)
    return CommandOutput(stdout: "", stderr: "", exitCode: 0, timedOut: false)
  }
}
