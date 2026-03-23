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
}
