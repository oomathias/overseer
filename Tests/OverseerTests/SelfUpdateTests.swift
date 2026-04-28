import XCTest

@testable import overseer

final class SelfUpdateTests: XCTestCase {
  func testInstallDirectoryUsesExecutableParentDirectory() throws {
    XCTAssertEqual(
      try SelfUpdateManager.installDirectory(forExecutablePath: "/usr/local/bin/overseer"),
      "/usr/local/bin"
    )
  }

  func testResolveCurrentExecutablePathUsesPATHLookupForBareCommandNames() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("overseer-tests-\(UUID().uuidString)", isDirectory: true)
    let binDir = root.appendingPathComponent("bin", isDirectory: true)
    let executablePath = binDir.appendingPathComponent("overseer")

    try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: root)
    }

    let contents = Data("#!/bin/sh\nexit 0\n".utf8)
    FileManager.default.createFile(atPath: executablePath.path, contents: contents)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o755))],
      ofItemAtPath: executablePath.path
    )

    let resolvedPath = try resolveCurrentExecutablePath(
      arguments: ["overseer"],
      currentDirectory: "/tmp",
      environment: ["PATH": binDir.path],
      bundleExecutablePath: nil
    )

    XCTAssertEqual(resolvedPath, executablePath.path)
  }

  func testResolveCurrentExecutablePathFallsBackToRelativeInvocationPath() throws {
    let resolvedPath = try resolveCurrentExecutablePath(
      arguments: ["./.build/debug/overseer"],
      currentDirectory: "/Users/test/project",
      environment: [:],
      bundleExecutablePath: nil
    )

    XCTAssertEqual(resolvedPath, "/Users/test/project/.build/debug/overseer")
  }

  func testUpdateDownloadsCurrentInstallerScript() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    var downloadedURL: URL?
    let manager = SelfUpdateManager(
      environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
      temporaryDirectory: root,
      executablePathResolver: { root.appendingPathComponent("bin/overseer").path },
      downloadScript: { sourceURL, destinationURL in
        downloadedURL = sourceURL
        try "exit 0\n".write(to: destinationURL, atomically: true, encoding: .utf8)
      }
    )

    _ = try manager.updateToLatest(stdoutHandler: nil, stderrHandler: nil)

    let source = try XCTUnwrap(downloadedURL)
    XCTAssertEqual(source.absoluteString, "https://raw.githubusercontent.com/oomathias/overseer/main/install")
  }

  func testUpdateIgnoresBashEnvironmentFromCaller() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let bashEnvURL = root.appendingPathComponent("bash-env")
    try "echo poisoned >&2\nexit 77\n".write(to: bashEnvURL, atomically: true, encoding: .utf8)

    let manager = SelfUpdateManager(
      environment: [
        "BASH_ENV": bashEnvURL.path,
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
      ],
      temporaryDirectory: root,
      executablePathResolver: { root.appendingPathComponent("bin/overseer").path },
      downloadScript: { _, destinationURL in
        try "exit 0\n".write(to: destinationURL, atomically: true, encoding: .utf8)
      }
    )

    XCTAssertNoThrow(try manager.updateToLatest(stdoutHandler: nil, stderrHandler: nil))
  }

  func testUpdateUsesTrustedPathForInstallerCommands() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let poisonedBin = root.appendingPathComponent("poisoned-bin", isDirectory: true)
    try FileManager.default.createDirectory(at: poisonedBin, withIntermediateDirectories: true)
    let poisonedAwk = poisonedBin.appendingPathComponent("awk")
    try """
    #!/bin/sh
    echo poisoned awk >&2
    exit 77
    """.write(to: poisonedAwk, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o755))],
      ofItemAtPath: poisonedAwk.path
    )

    let manager = SelfUpdateManager(
      environment: [
        "PATH": "\(poisonedBin.path):/usr/bin:/bin:/usr/sbin:/sbin"
      ],
      temporaryDirectory: root,
      executablePathResolver: { root.appendingPathComponent("bin/overseer").path },
      downloadScript: { _, destinationURL in
        try "awk 'BEGIN { exit 0 }'\n".write(to: destinationURL, atomically: true, encoding: .utf8)
      }
    )

    XCTAssertNoThrow(try manager.updateToLatest(stdoutHandler: nil, stderrHandler: nil))
  }

  private func makeTempDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("overseer-self-update-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}
