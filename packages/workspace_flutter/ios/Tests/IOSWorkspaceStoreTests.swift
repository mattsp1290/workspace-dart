import Foundation
import XCTest
@testable import WorkspaceFlutterNative

final class IOSWorkspaceStoreTests: XCTestCase {
  func testP08KeepsPrivateMappingsAndRootBoundToOneWorkspace() {
    let (store, defaults, suite) = makeStore()
    defer { defaults.removePersistentDomain(forName: suite) }

    let root = IOSRootRecord(
      identity: "root-one", generation: 1, rootID: "abcdefghijklmnopqrstuv", digest: Data(repeating: 1, count: 32), phase: "pending"
    )
    XCTAssertTrue(store.saveRootRecord(root, workspaceId: "one"))
    XCTAssertTrue(store.saveRecords([
      "root": IOSLineageRecord(parentID: nil, relativePath: ""),
      "entry": IOSLineageRecord(parentID: "root", relativePath: "nested/file"),
    ], workspaceId: "one"))

    XCTAssertEqual(store.rootRecord(workspaceId: "one"), root)
    XCTAssertTrue(store.promoteRoot(workspaceId: "one"))
    XCTAssertEqual(store.rootRecord(workspaceId: "one")?.phase, "active")
    XCTAssertEqual(store.records(workspaceId: "one")?["entry"],
                   IOSLineageRecord(parentID: "root", relativePath: "nested/file"))
    XCTAssertNil(store.rootRecord(workspaceId: "two"))
    XCTAssertTrue(store.records(workspaceId: "two")?.isEmpty == true)
  }

  func testC03RemovesBothRootAndPrivateLineageForForgottenWorkspace() {
    let (store, defaults, suite) = makeStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    XCTAssertTrue(store.saveRootRecord(IOSRootRecord(
      identity: "root", generation: 1, rootID: "abcdefghijklmnopqrstuv", digest: Data(repeating: 1, count: 32), phase: "active"
    ), workspaceId: "one"))
    XCTAssertTrue(store.saveRecords([
      "root": IOSLineageRecord(parentID: nil, relativePath: ""),
      "entry": IOSLineageRecord(parentID: "root", relativePath: "file"),
    ], workspaceId: "one"))

    XCTAssertTrue(store.removeWorkspace("one"))
    XCTAssertNil(store.rootRecord(workspaceId: "one"))
    XCTAssertTrue(store.records(workspaceId: "one")?.isEmpty == true)
    XCTAssertFalse(store.storedWorkspaceIDs().contains("one"))
  }

  func testC03ReconciliationFindsRootOnlyCrashState() {
    let (store, defaults, suite) = makeStore()
    defer { defaults.removePersistentDomain(forName: suite) }

    XCTAssertTrue(store.saveRootRecord(IOSRootRecord(
      identity: "root", generation: 1, rootID: "abcdefghijklmnopqrstuv", digest: Data(repeating: 1, count: 32), phase: "active"
    ), workspaceId: "root-only"))
    XCTAssertTrue(store.storedWorkspaceIDs().contains("root-only"))
    XCTAssertTrue(store.removeWorkspace("root-only"))
    XCTAssertFalse(store.storedWorkspaceIDs().contains("root-only"))
  }

  func testP08RejectsUnversionedPathOnlyLineage() {
    let (store, defaults, suite) = makeStore()
    defer { defaults.removePersistentDomain(forName: suite) }

    defaults.set(["entry": "nested/file"], forKey: "workspace_flutter.entries.one")

    XCTAssertNil(store.records(workspaceId: "one"))
  }

  func testP08RejectsMalformedPrivateParentID() {
    let (store, defaults, suite) = makeStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set([
      "entry": ["version": 1, "parentID": "not/a/stable-id", "relativePath": "file"],
    ], forKey: "workspace_flutter.entries.one")

    XCTAssertNil(store.records(workspaceId: "one"))
  }

  func testP04RejectsAnUnversionedRootAuthorityRecord() {
    let (store, defaults, suite) = makeStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("legacy-root-path", forKey: "workspace_flutter.root-binding.one")

    XCTAssertTrue(store.hasRootState(workspaceId: "one"))
    XCTAssertNil(store.rootRecord(workspaceId: "one"))
  }

  private func makeStore() -> (IOSWorkspaceStore, UserDefaults, String) {
    let suite = "workspace_flutter.native.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    return (UserDefaultsIOSWorkspaceStore(defaults: defaults), defaults, suite)
  }
}
