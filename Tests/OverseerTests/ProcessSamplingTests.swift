import XCTest

@testable import overseer

final class ProcessSamplingTests: XCTestCase {
  func testExecutablePathCacheRetriesAfterFailedLookup() {
    var cache = ExecutablePathCache()
    let startTime = ProcessStartTime(seconds: 10, microseconds: 0)
    var attempts = 0

    let first = cache.resolve(pid: 42, startTime: startTime) { _ in
      attempts += 1
      return nil
    }
    XCTAssertNil(first)
    XCTAssertEqual(attempts, 1)

    let second = cache.resolve(pid: 42, startTime: startTime) { _ in
      attempts += 1
      return "/usr/local/bin/node"
    }
    XCTAssertEqual(second, "/usr/local/bin/node")
    XCTAssertEqual(attempts, 2)

    let third = cache.resolve(pid: 42, startTime: startTime) { _ in
      attempts += 1
      return "/usr/local/bin/other"
    }
    XCTAssertEqual(third, "/usr/local/bin/node")
    XCTAssertEqual(attempts, 2)
  }
}
