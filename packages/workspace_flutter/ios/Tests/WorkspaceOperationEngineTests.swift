import XCTest
@testable import WorkspaceFlutterNative

final class WorkspaceOperationEngineTests: XCTestCase {
  func testC01CancellationIsVisibleToTheTerminalSettlementOwner() {
    let engine = WorkspaceOperationEngine()
    let entered = expectation(description: "operation started")
    let settled = expectation(description: "operation settled")
    let release = DispatchSemaphore(value: 0)

    XCTAssertTrue(engine.run(
      operationId: "cancelled-operation",
      workspaceId: "workspace",
      remainingMillis: 1_000,
      settle: { operation, terminal in
        XCTAssertTrue(operation.isCancelled())
        guard case let .success(value) = terminal else {
          return XCTFail("body should complete; the handler maps the cancelled operation")
        }
        XCTAssertEqual(value as? String, "complete")
        settled.fulfill()
      },
      body: { _, _ in
        entered.fulfill()
        _ = release.wait(timeout: .now() + 1)
        return "complete"
      }
    ))
    wait(for: [entered], timeout: 1)
    engine.cancel("cancelled-operation")
    release.signal()
    wait(for: [settled], timeout: 1)
  }

  func testC02RejectsDuplicateIDAndSettlesTheOriginalOperationOnce() {
    let engine = WorkspaceOperationEngine()
    let settled = expectation(description: "first operation settles")
    let hold = DispatchSemaphore(value: 0)
    var settlements = 0

    XCTAssertTrue(engine.run(
      operationId: "operation",
      workspaceId: "workspace",
      remainingMillis: 1_000,
      settle: { _, terminal in
        settlements += 1
        guard case let .success(value) = terminal else {
          return XCTFail("expected successful terminal result")
        }
        XCTAssertEqual(value as? String, "complete")
        settled.fulfill()
      },
      body: { _, _ in
        _ = hold.wait(timeout: .now() + 1)
        return "complete"
      }
    ))

    XCTAssertFalse(engine.run(
      operationId: "operation",
      workspaceId: "other-workspace",
      remainingMillis: 1_000,
      settle: { _, _ in XCTFail("duplicate operation must not settle") },
      body: { _, _ in "unexpected" }
    ))

    hold.signal()
    wait(for: [settled], timeout: 1)
    XCTAssertEqual(settlements, 1)
  }

  func testC03DetachFencesALateCallbackAndNewEngineCanRun() {
    let engine = WorkspaceOperationEngine()
    let entered = expectation(description: "operation started")
    let staleReply = expectation(description: "stale reply")
    staleReply.isInverted = true
    let release = DispatchSemaphore(value: 0)

    XCTAssertTrue(engine.run(
      operationId: "stale-operation",
      workspaceId: "workspace",
      remainingMillis: 1_000,
      settle: { _, _ in staleReply.fulfill() },
      body: { _, _ in
        entered.fulfill()
        _ = release.wait(timeout: .now() + 1)
        return "late"
      }
    ))
    wait(for: [entered], timeout: 1)
    engine.detach()
    release.signal()
    wait(for: [staleReply], timeout: 0.1)
    XCTAssertFalse(engine.run(
      operationId: "while-detached",
      workspaceId: "workspace",
      remainingMillis: 1_000,
      settle: { _, _ in XCTFail("detached engine must not settle") },
      body: { _, _ in "unexpected" }
    ))

    let replacement = WorkspaceOperationEngine()
    let freshReply = expectation(description: "replacement settles")
    XCTAssertTrue(replacement.run(
      operationId: "fresh-operation",
      workspaceId: "fresh-workspace",
      remainingMillis: 1_000,
      settle: { _, terminal in
        guard case let .success(value) = terminal else {
          return XCTFail("replacement engine should succeed")
        }
        XCTAssertEqual(value as? String, "fresh")
        freshReply.fulfill()
      },
      body: { _, _ in "fresh" }
    ))
    wait(for: [freshReply], timeout: 1)
  }
}
