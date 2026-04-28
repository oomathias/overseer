import Darwin
import XCTest

@testable import overseer

final class SignalSenderTests: XCTestCase {
  func testSendRefusesWhenStartTimeChanged() {
    var sentSignals: [(pid_t, Int32)] = []
    let sender = DarwinSignalSender(
      identityResolver: { _ in
        ProcessSignalIdentity(
          startTime: ProcessStartTime(seconds: 11, microseconds: 0),
          executableName: "node"
        )
      },
      killFunction: { pid, signal in
        sentSignals.append((pid, signal))
        return 0
      }
    )

    XCTAssertThrowsError(
      try sender.send(
        pid: 42,
        signal: .term,
        expectedIdentity: ProcessSignalIdentity(
          startTime: ProcessStartTime(seconds: 10, microseconds: 0),
          executableName: "node"
        )
      )
    )
    XCTAssertTrue(sentSignals.isEmpty)
  }

  func testSendRefusesWhenExecutableNameChanged() {
    var sentSignals: [(pid_t, Int32)] = []
    let sender = DarwinSignalSender(
      identityResolver: { _ in
        ProcessSignalIdentity(
          startTime: ProcessStartTime(seconds: 10, microseconds: 0),
          executableName: "python"
        )
      },
      killFunction: { pid, signal in
        sentSignals.append((pid, signal))
        return 0
      }
    )

    XCTAssertThrowsError(
      try sender.send(
        pid: 42,
        signal: .term,
        expectedIdentity: ProcessSignalIdentity(
          startTime: ProcessStartTime(seconds: 10, microseconds: 0),
          executableName: "node"
        )
      )
    )
    XCTAssertTrue(sentSignals.isEmpty)
  }

  func testSendSignalsWhenIdentityMatches() throws {
    var sentSignals: [(pid_t, Int32)] = []
    let sender = DarwinSignalSender(
      identityResolver: { _ in
        ProcessSignalIdentity(
          startTime: ProcessStartTime(seconds: 10, microseconds: 0),
          executableName: "node"
        )
      },
      killFunction: { pid, signal in
        sentSignals.append((pid, signal))
        return 0
      }
    )

    try sender.send(
      pid: 42,
      signal: .term,
      expectedIdentity: ProcessSignalIdentity(
        startTime: ProcessStartTime(seconds: 10, microseconds: 0),
        executableName: "node"
      )
    )

    XCTAssertEqual(sentSignals.count, 1)
    XCTAssertEqual(sentSignals.first?.0, pid_t(42))
    XCTAssertEqual(sentSignals.first?.1, SIGTERM)
  }
}
