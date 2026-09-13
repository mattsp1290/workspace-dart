import Flutter
import UIKit
import XCTest
import CryptoKit
@testable import workspace_flutter

final class RunnerTests: XCTestCase {
  func testProductionPluginRegistersWithARunningFlutterEngine() {
    let engine = FlutterEngine(name: "WorkspacePluginXCTest")
    XCTAssertTrue(engine.run())
    guard let registrar = engine.registrar(forPlugin: "WorkspaceFlutterPluginXCTest") else {
      return XCTFail("Flutter engine did not provide a plugin registrar")
    }

    WorkspaceFlutterPlugin.register(with: registrar)
  }

  func testC03IgnoresALatePickerCallbackAfterItsRequestIsGone() {
    let suite = "workspace-flutter-runner-late-picker-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let plugin = WorkspaceFlutterPlugin(
      bookmarkProvider: LocalFixtureBookmarkProvider(root: FileManager.default.temporaryDirectory),
      workspaceStore: UserDefaultsIOSWorkspaceStore(defaults: defaults)
    )
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)

    // No selection is pending: UIKit's late delegate callback must be inert.
    plugin.documentPicker(picker, didPickDocumentsAt: [FileManager.default.temporaryDirectory])
    XCTAssertTrue(UserDefaultsIOSWorkspaceStore(defaults: defaults).storedWorkspaceIDs().isEmpty)
  }

  func testC03CommitAndAbandonSelectionDriveThePersistedRootPhase() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("workspace-flutter-runner-phase-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "workspace-flutter-runner-phase-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = UserDefaultsIOSWorkspaceStore(defaults: defaults)
    let rootRecord = IOSRootRecord(
      identity: root.resolvingSymlinksInPath().standardizedFileURL.path,
      generation: 1,
      rootID: "abcdefghijklmnopqrstuv",
      digest: Data(SHA256.hash(data: Data(root.resolvingSymlinksInPath().standardizedFileURL.path.utf8))),
      phase: "pending"
    )
    XCTAssertTrue(store.saveRootRecord(rootRecord, workspaceId: "phase-workspace"))
    let plugin = WorkspaceFlutterPlugin(
      bookmarkProvider: LocalFixtureBookmarkProvider(root: root), workspaceStore: store
    )

    try invokeVoid(plugin, method: "commitSelection", arguments: [
      "protocolVersion": 1,
      "workspaceId": "phase-workspace",
    ])
    XCTAssertEqual(store.rootRecord(workspaceId: "phase-workspace")?.phase, "active")
    try invokeVoid(plugin, method: "abandonSelection", arguments: [
      "protocolVersion": 1,
      "workspaceId": "phase-workspace",
    ])
    XCTAssertNil(store.rootRecord(workspaceId: "phase-workspace"))
  }

  func testC03DetachFencesALivePluginOperationAndAReplacementCanServeCalls() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("workspace-flutter-runner-detach-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("fixture".utf8).write(to: root.appendingPathComponent("entry.txt"))

    let operationStarted = expectation(description: "list entered provider work")
    let cleanupFinished = expectation(description: "detached operation released its scope")
    let staleReply = expectation(description: "detached operation must not reply")
    staleReply.isInverted = true
    let provider = LifecycleFixtureBookmarkProvider(
      root: root,
      operationStarted: operationStarted,
      cleanupFinished: cleanupFinished
    )
    let suite = "workspace-flutter-runner-detach-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let plugin = WorkspaceFlutterPlugin(
      bookmarkProvider: provider,
      workspaceStore: UserDefaultsIOSWorkspaceStore(defaults: defaults)
    )
    let envelope = fixtureEnvelope(root: root)
    let workspaceId = "detach-workspace"
    let restored = try invoke(plugin, method: "restore", arguments: [
      "protocolVersion": 1,
      "workspaceId": workspaceId,
      "envelope": envelope,
    ]) as! [String: Any]
    let rootId = try XCTUnwrap(restored["entryId"] as? String)

    plugin.handle(FlutterMethodCall(methodName: "list", arguments: [
      "protocolVersion": 1,
      "workspaceId": workspaceId,
      "envelope": envelope,
      "directoryId": rootId,
      "maxEntries": 1,
      "maxBytes": 1024,
      "cursor": NSNull(),
      "operationId": "detach-list",
      "remainingMillis": 10_000,
    ])) { _ in
      staleReply.fulfill()
    }
    wait(for: [operationStarted], timeout: 1)

    let engine = FlutterEngine(name: "WorkspacePluginDetachXCTest")
    XCTAssertTrue(engine.run())
    let registrar = try XCTUnwrap(engine.registrar(forPlugin: "WorkspaceFlutterPluginDetachXCTest"))
    plugin.detachFromEngine(for: registrar)
    wait(for: [cleanupFinished, staleReply], timeout: 1)
    XCTAssertEqual(provider.started, provider.stopped)

    let replacementSuite = "workspace-flutter-runner-detach-replacement-\(UUID().uuidString)"
    let replacementDefaults = UserDefaults(suiteName: replacementSuite)!
    defer { replacementDefaults.removePersistentDomain(forName: replacementSuite) }
    let replacement = WorkspaceFlutterPlugin(
      bookmarkProvider: LocalFixtureBookmarkProvider(root: root),
      workspaceStore: UserDefaultsIOSWorkspaceStore(defaults: replacementDefaults)
    )
    let replacementResult = try invoke(replacement, method: "restore", arguments: [
      "protocolVersion": 1,
      "workspaceId": "replacement-workspace",
      "envelope": envelope,
    ]) as? [String: Any]
    XCTAssertNotNil(replacementResult?["entryId"] as? String)
    engine.destroyContext()
  }

  func testA01A02L01R01R02R03ControlledRootTraversesTheProductionHandler() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("workspace-flutter-runner-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("fixture".utf8).write(to: root.appendingPathComponent("entry.txt"))

    let provider = LocalFixtureBookmarkProvider(root: root)
    let suite = "workspace-flutter-runner-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let plugin = WorkspaceFlutterPlugin(
      bookmarkProvider: provider,
      workspaceStore: UserDefaultsIOSWorkspaceStore(defaults: defaults)
    )
    let envelope = fixtureEnvelope(root: root)
    let workspaceId = "test-workspace"

    let restored = try invoke(plugin, method: "restore", arguments: [
      "protocolVersion": 1,
      "workspaceId": workspaceId,
      "envelope": envelope,
    ]) as! [String: Any]
    let rootId = try XCTUnwrap(restored["entryId"] as? String)

    let page = try invoke(plugin, method: "list", arguments: [
      "protocolVersion": 1,
      "workspaceId": workspaceId,
      "envelope": envelope,
      "directoryId": rootId,
      "maxEntries": 10,
      "maxBytes": 1024,
      "cursor": NSNull(),
      "operationId": "fixture-list",
      "remainingMillis": 10_000,
    ]) as! [String: Any]
    let rows = try XCTUnwrap(page["entries"] as? [[String: Any]])
    XCTAssertEqual(rows.count, 1)
    let fileId = try XCTUnwrap(rows[0]["entryId"] as? String)

    func read(
      offset: Int,
      count: Int,
      expectedRevision: Any = NSNull(),
      operationId: String
    ) throws -> [String: Any] {
      try invoke(plugin, method: "read", arguments: [
        "protocolVersion": 1,
        "workspaceId": workspaceId,
        "envelope": envelope,
        "fileId": fileId,
        "offset": offset,
        "count": count,
        "maxBytes": 64,
        "expectedRevision": expectedRevision,
        "operationId": operationId,
        "remainingMillis": 10_000,
      ]) as! [String: Any]
    }

    let initialRead = try read(offset: 0, count: 64, operationId: "fixture-read")
    let bytes = try XCTUnwrap((initialRead["bytes"] as? FlutterStandardTypedData)?.data)
    XCTAssertEqual(String(data: bytes, encoding: .utf8), "fixture")
    let zero = try read(offset: 0, count: 0, operationId: "fixture-zero")
    XCTAssertTrue(try XCTUnwrap((zero["bytes"] as? FlutterStandardTypedData)?.data).isEmpty)
    let pastEnd = try read(offset: 4_096, count: 64, operationId: "fixture-past-end")
    XCTAssertTrue(try XCTUnwrap((pastEnd["bytes"] as? FlutterStandardTypedData)?.data).isEmpty)
    XCTAssertEqual(pastEnd["eof"] as? Bool, true)
    let revision = try read(
      offset: 0,
      count: 64,
      expectedRevision: ["kind": "wholeContentSha256", "value": String(repeating: "0", count: 64)],
      operationId: "fixture-revision"
    )
    XCTAssertEqual(revision["stability"] as? String, "unverified")

    assertFlutterError("unsupported") {
      try invoke(plugin, method: "read", arguments: [
        "protocolVersion": 1,
        "workspaceId": workspaceId,
        "envelope": envelope,
        "fileId": rootId,
        "offset": 0,
        "count": 64,
        "maxBytes": 64,
        "expectedRevision": NSNull(),
        "operationId": "fixture-directory-read",
        "remainingMillis": 10_000,
      ])
    }
    assertFlutterError("invalidReference") {
      _ = try invoke(plugin, method: "restore", arguments: [
        "protocolVersion": 1,
        "workspaceId": "other-workspace",
        "envelope": envelope,
      ])
      return try invoke(plugin, method: "list", arguments: [
        "protocolVersion": 1,
        "workspaceId": workspaceId,
        "envelope": envelope,
        "directoryId": "missing-entry",
        "maxEntries": 10,
        "maxBytes": 1024,
        "cursor": NSNull(),
        "operationId": "fixture-missing-entry",
        "remainingMillis": 10_000,
      ])
    }
    assertFlutterError("invalidReference") {
      try invoke(plugin, method: "list", arguments: [
        "protocolVersion": 1,
        "workspaceId": "other-workspace",
        "envelope": envelope,
        "directoryId": fileId,
        "maxEntries": 10,
        "maxBytes": 1024,
        "cursor": NSNull(),
        "operationId": "fixture-cross-workspace",
        "remainingMillis": 10_000,
      ])
    }
    XCTAssertEqual(provider.started, 8)
    XCTAssertEqual(provider.stopped, 8)
  }

  func testL03RejectsSnapshotThatExceedsTheNativeEntryBound() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("workspace-flutter-runner-overflow-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for index in 0...1_000 {
      try Data().write(to: root.appendingPathComponent("item-\(index).txt"))
    }

    let provider = LocalFixtureBookmarkProvider(root: root)
    let suite = "workspace-flutter-runner-overflow-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let plugin = WorkspaceFlutterPlugin(
      bookmarkProvider: provider,
      workspaceStore: UserDefaultsIOSWorkspaceStore(defaults: defaults)
    )
    let envelope = fixtureEnvelope(root: root)
    let workspaceId = "overflow-workspace"
    let rootResult = try invoke(plugin, method: "restore", arguments: [
      "protocolVersion": 1,
      "workspaceId": workspaceId,
      "envelope": envelope,
    ]) as! [String: Any]
    let rootId = try XCTUnwrap(rootResult["entryId"] as? String)

    assertFlutterError("unsupported") {
      try invoke(plugin, method: "list", arguments: [
        "protocolVersion": 1,
        "workspaceId": workspaceId,
        "envelope": envelope,
        "directoryId": rootId,
        "maxEntries": 1_000,
        "maxBytes": 1_024 * 1_024,
        "cursor": NSNull(),
        "operationId": "overflow-list",
        "remainingMillis": 10_000,
      ])
    }
    XCTAssertEqual(provider.started, 2)
    XCTAssertEqual(provider.stopped, 2)
  }

  func testS01PublicErrorsContainOnlyTheWireFailure() {
    let marker = "workspace-private-marker"
    let root = URL(fileURLWithPath: "/tmp/\(marker)", isDirectory: true)
    let suite = "workspace-flutter-runner-privacy-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let plugin = WorkspaceFlutterPlugin(
      bookmarkProvider: LocalFixtureBookmarkProvider(root: root),
      workspaceStore: UserDefaultsIOSWorkspaceStore(defaults: defaults)
    )
    let settled = expectation(description: "invalid reference")
    var response: Any?
    plugin.handle(FlutterMethodCall(methodName: "list", arguments: [
      "protocolVersion": 1,
      "workspaceId": "privacy-workspace",
      "envelope": fixtureEnvelope(root: root),
      "directoryId": "missing-entry",
      "maxEntries": 1,
      "maxBytes": 1,
      "cursor": NSNull(),
      "operationId": "privacy-list",
      "remainingMillis": 1_000,
    ])) { value in
      response = value
      settled.fulfill()
    }
    wait(for: [settled], timeout: 1)

    let error = response as? FlutterError
    XCTAssertEqual(error?.code, "permissionLost")
    XCTAssertNil(error?.message)
    XCTAssertNil(error?.details)
    XCTAssertFalse(String(describing: error).contains(marker))
  }

  private func assertFlutterError(_ expected: String, body: () throws -> Any) {
    XCTAssertThrowsError(try body()) { error in
      XCTAssertEqual(error as? InvocationError, .flutter(expected))
    }
  }

  private func invoke(
    _ plugin: WorkspaceFlutterPlugin,
    method: String,
    arguments: [String: Any]
  ) throws -> Any {
    let settled = expectation(description: method)
    var response: Any?
    plugin.handle(FlutterMethodCall(methodName: method, arguments: arguments)) { value in
      response = value
      settled.fulfill()
    }
    wait(for: [settled], timeout: 3)
    if let error = response as? FlutterError {
      throw InvocationError.flutter(error.code)
    }
    return try XCTUnwrap(response)
  }

  private func invokeVoid(
    _ plugin: WorkspaceFlutterPlugin,
    method: String,
    arguments: [String: Any]
  ) throws {
    let settled = expectation(description: method)
    var response: Any?
    plugin.handle(FlutterMethodCall(methodName: method, arguments: arguments)) { value in
      response = value
      settled.fulfill()
    }
    wait(for: [settled], timeout: 3)
    if let error = response as? FlutterError { throw InvocationError.flutter(error.code) }
    XCTAssertNil(response)
  }
}

private enum InvocationError: Error, Equatable {
  case flutter(String)
}

private func fixtureEnvelope(root: URL) -> FlutterStandardTypedData {
  FlutterStandardTypedData(bytes: WorkspaceProtocol.iOSEnvelope(
    bookmark: Data([1]), generation: 1, rootID: "abcdefghijklmnopqrstuv",
    rootDigest: Data(SHA256.hash(data: Data(root.resolvingSymlinksInPath().standardizedFileURL.path.utf8)))
  )!)
}

private final class LocalFixtureBookmarkProvider: IOSBookmarkProvider {
  let root: URL
  private(set) var started = 0
  private(set) var stopped = 0

  init(root: URL) {
    self.root = root
  }

  func resolve(_: Data) throws -> IOSResolvedBookmark {
    IOSResolvedBookmark(root: root, isStale: false)
  }

  func startAccessing(_: URL) -> Bool {
    started += 1
    return true
  }

  func stopAccessing(_: URL) {
    stopped += 1
  }
}

private final class LifecycleFixtureBookmarkProvider: IOSBookmarkProvider {
  let root: URL
  let operationStarted: XCTestExpectation
  let cleanupFinished: XCTestExpectation
  private(set) var started = 0
  private(set) var stopped = 0

  init(
    root: URL,
    operationStarted: XCTestExpectation,
    cleanupFinished: XCTestExpectation
  ) {
    self.root = root
    self.operationStarted = operationStarted
    self.cleanupFinished = cleanupFinished
  }

  func resolve(_: Data) throws -> IOSResolvedBookmark {
    IOSResolvedBookmark(root: root, isStale: false)
  }

  func startAccessing(_: URL) -> Bool {
    started += 1
    return true
  }

  func stopAccessing(_: URL) {
    stopped += 1
    if stopped == 2 {
      cleanupFinished.fulfill()
    }
  }

  func beforeList(_: URL, isCancelled: () -> Bool) throws {
    operationStarted.fulfill()
    let expiry = ProcessInfo.processInfo.systemUptime + 1
    while !isCancelled() && ProcessInfo.processInfo.systemUptime < expiry {
      Thread.sleep(forTimeInterval: 0.005)
    }
    if !isCancelled() {
      throw IOSProviderFailure()
    }
  }
}
