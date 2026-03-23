import Foundation
import XCTest

@testable import overseer

final class CommandRunnerTests: XCTestCase {
  func testRunStreamsStdoutAndStderrWhileCapturingOutput() throws {
    let stream = OutputStreamBox()

    let output = try CommandRunner().run(
      program: "/bin/sh",
      arguments: ["-c", "printf 'hello\\n'; printf 'warn\\n' >&2"],
      timeout: 5,
      stdoutHandler: { chunk in
        stream.appendStdout(chunk)
      },
      stderrHandler: { chunk in
        stream.appendStderr(chunk)
      }
    )

    XCTAssertEqual(output.stdout, "hello\n")
    XCTAssertEqual(output.stderr, "warn\n")
    XCTAssertEqual(stream.stdoutString, "hello\n")
    XCTAssertEqual(stream.stderrString, "warn\n")
  }
}

private final class OutputStreamBox: @unchecked Sendable {
  private let lock = NSLock()
  private var stdout = Data()
  private var stderr = Data()

  var stdoutString: String {
    lock.lock()
    defer { lock.unlock() }
    return String(decoding: stdout, as: UTF8.self)
  }

  var stderrString: String {
    lock.lock()
    defer { lock.unlock() }
    return String(decoding: stderr, as: UTF8.self)
  }

  func appendStdout(_ chunk: Data) {
    lock.lock()
    defer { lock.unlock() }
    stdout.append(chunk)
  }

  func appendStderr(_ chunk: Data) {
    lock.lock()
    defer { lock.unlock() }
    stderr.append(chunk)
  }
}
