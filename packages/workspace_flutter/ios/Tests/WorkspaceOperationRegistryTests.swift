import XCTest
@testable import WorkspaceFlutterNative

final class WorkspaceOperationRegistryTests: XCTestCase {
  func testC02RejectsDuplicateOperationIDsWithoutReplacingLiveWork() {
    let registry = WorkspaceOperationRegistry()
    let first = registry.register(operationId: "operation", workspaceId: "one", engineGeneration: 1)

    XCTAssertNotNil(first)
    XCTAssertNil(registry.register(operationId: "operation", workspaceId: "two", engineGeneration: 1))
    XCTAssertEqual(registry.activeCount, 1)
    XCTAssertTrue(registry.hasLiveWorkspace("one"))
    XCTAssertFalse(registry.hasLiveWorkspace("two"))
  }

  func testC03CancelsOnlyMatchingWorkspaceUntilCleanupRemovesIt() {
    let registry = WorkspaceOperationRegistry()
    let one = registry.register(operationId: "one", workspaceId: "workspace-one", engineGeneration: 1)!
    let two = registry.register(operationId: "two", workspaceId: "workspace-two", engineGeneration: 1)!

    registry.closeWorkspace("workspace-one")

    XCTAssertTrue(one.isCancelled())
    XCTAssertFalse(two.isCancelled())
    XCTAssertTrue(registry.hasLiveWorkspace("workspace-one"))
    registry.remove("one")
    XCTAssertFalse(registry.hasLiveWorkspace("workspace-one"))
    XCTAssertTrue(registry.hasLiveWorkspace("workspace-two"))
  }

  func testC03ClosingWorkspacePreventsLateOperationRegistration() {
    let registry = WorkspaceOperationRegistry()
    registry.closeWorkspace("workspace")

    XCTAssertTrue(registry.isWorkspaceClosing("workspace"))
    XCTAssertNil(registry.register(operationId: "late", workspaceId: "workspace", engineGeneration: 1))
  }

  func testC03CleanupBarrierWaitsForHeldMatchingOperation() {
    let registry = WorkspaceOperationRegistry()
    _ = registry.register(operationId: "one", workspaceId: "workspace", engineGeneration: 1)
    let waiting = DispatchSemaphore(value: 0)
    let released = DispatchSemaphore(value: 0)

    DispatchQueue.global().async {
      waiting.signal()
      registry.awaitWorkspaceCleanup("workspace")
      released.signal()
    }

    XCTAssertEqual(waiting.wait(timeout: .now() + 1), .success)
    XCTAssertEqual(released.wait(timeout: .now() + 0.05), .timedOut)
    registry.remove("one")
    XCTAssertEqual(released.wait(timeout: .now() + 1), .success)
  }
}
