import Foundation
import XCTest
@testable import WorkspaceFlutterNative

final class IOSBookmarkProviderTests: XCTestCase {
  func testP11BalancesSecurityScopeAfterSuccessfulWork() throws {
    let provider = FakeBookmarkProvider()
    let result = try IOSRootAccess.withRoot(bookmark: Data([1]), provider: provider) { root in
      root.lastPathComponent
    }

    XCTAssertEqual(result, "workspace")
    XCTAssertEqual(provider.started, 1)
    XCTAssertEqual(provider.stopped, 1)
  }

  func testP11BalancesSecurityScopeAfterProviderWorkThrows() {
    let provider = FakeBookmarkProvider()

    XCTAssertThrowsError(try IOSRootAccess.withRoot(bookmark: Data([1]), provider: provider) { _ in
      throw TestFailure.expected
    })
    XCTAssertEqual(provider.started, 1)
    XCTAssertEqual(provider.stopped, 1)
  }

  func testP04RejectsMalformedBookmarkWithoutStartingScope() {
    let provider = FakeBookmarkProvider(resolveError: TestFailure.expected)

    XCTAssertThrowsError(try IOSRootAccess.withRoot(bookmark: Data([1]), provider: provider) { _ in }) {
      XCTAssertEqual($0 as? IOSRootAccessError, .invalidBookmark)
    }
    XCTAssertEqual(provider.started, 0)
    XCTAssertEqual(provider.stopped, 0)
  }

  func testP11FailedScopeStartIsNotStopped() {
    let provider = FakeBookmarkProvider(allowsAccess: false)

    XCTAssertThrowsError(try IOSRootAccess.withRoot(bookmark: Data([1]), provider: provider) { _ in }) {
      XCTAssertEqual($0 as? IOSRootAccessError, .permissionLost)
    }
    XCTAssertEqual(provider.started, 1)
    XCTAssertEqual(provider.stopped, 0)
  }

  func testA03StaleBookmarkFailsAsPermissionLostWithoutStartingScope() {
    let provider = FakeBookmarkProvider(isStale: true)

    XCTAssertThrowsError(try IOSRootAccess.withRoot(bookmark: Data([1]), provider: provider) { _ in }) {
      XCTAssertEqual($0 as? IOSRootAccessError, .permissionLost)
    }
    XCTAssertEqual(provider.started, 0)
    XCTAssertEqual(provider.stopped, 0)
  }
}

private final class FakeBookmarkProvider: IOSBookmarkProvider {
  private let resolveError: Error?
  private let allowsAccess: Bool
  private let isStale: Bool
  var started = 0
  var stopped = 0

  init(resolveError: Error? = nil, allowsAccess: Bool = true, isStale: Bool = false) {
    self.resolveError = resolveError
    self.allowsAccess = allowsAccess
    self.isStale = isStale
  }

  func resolve(_ bookmark: Data) throws -> IOSResolvedBookmark {
    if let resolveError { throw resolveError }
    return IOSResolvedBookmark(root: URL(fileURLWithPath: "/tmp/workspace"), isStale: isStale)
  }

  func startAccessing(_ root: URL) -> Bool {
    started += 1
    return allowsAccess
  }

  func stopAccessing(_ root: URL) {
    stopped += 1
  }
}

private enum TestFailure: Error {
  case expected
}
