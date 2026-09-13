import Foundation

/// Bookmark and security-scope boundary used by the native operation engine.
///
/// The production implementation is intentionally small: operation code owns
/// the `defer` that balances a successful start, while this seam owns the
/// platform calls. XCTest fakes can therefore model stale bookmarks, failed
/// scope acquisition, and verify that every started scope is stopped.
internal protocol IOSBookmarkProvider {
  func resolve(_ bookmark: Data) throws -> IOSResolvedBookmark
  func startAccessing(_ root: URL) -> Bool
  func stopAccessing(_ root: URL)
  /// Testable provider boundary before a coordinated directory enumeration.
  func beforeList(_ root: URL, isCancelled: () -> Bool) throws
  /// Testable provider boundary before coordinated file access.
  func beforeRead(_ root: URL, isCancelled: () -> Bool) throws
}

internal extension IOSBookmarkProvider {
  func beforeList(_: URL, isCancelled _: () -> Bool) throws {}
  func beforeRead(_: URL, isCancelled _: () -> Bool) throws {}
}

internal struct IOSResolvedBookmark {
  let root: URL
  let isStale: Bool
}

/// A provider could not serve a request, without exposing provider diagnostics.
internal struct IOSProviderUnavailable: Error {}

/// A provider failed after authority validation, without exposing diagnostics.
internal struct IOSProviderFailure: Error {}

internal enum IOSRootAccessError: Error, Equatable {
  case invalidBookmark
  case permissionLost
}

/// Keeps the security-scope balancing invariant independent of Flutter.
internal enum IOSRootAccess {
  static func withRoot<T>(
    bookmark: Data,
    provider: IOSBookmarkProvider,
    body: (URL) throws -> T
  ) throws -> T {
    let resolved: IOSResolvedBookmark
    do {
      resolved = try provider.resolve(bookmark)
    } catch {
      throw IOSRootAccessError.invalidBookmark
    }
    guard !resolved.isStale, provider.startAccessing(resolved.root) else {
      throw IOSRootAccessError.permissionLost
    }
    defer { provider.stopAccessing(resolved.root) }
    return try body(resolved.root.standardizedFileURL)
  }
}

internal final class FoundationIOSBookmarkProvider: IOSBookmarkProvider {
  func resolve(_ bookmark: Data) throws -> IOSResolvedBookmark {
    var stale = false
    let root = try URL(
      resolvingBookmarkData: bookmark,
      options: [],
      relativeTo: nil,
      bookmarkDataIsStale: &stale
    )
    return IOSResolvedBookmark(root: root, isStale: stale)
  }

  func startAccessing(_ root: URL) -> Bool {
    root.startAccessingSecurityScopedResource()
  }

  func stopAccessing(_ root: URL) {
    root.stopAccessingSecurityScopedResource()
  }
}

#if WORKSPACE_NATIVE_TEST_FIXTURE
/// Compiled only into the explicit iOS integration-test flavor. It permits the
/// Flutter test to traverse the registered production channel handler without
/// exposing a fixture switch through the public Dart API.
internal final class NativeTestBookmarkProvider: IOSBookmarkProvider {
  static let envelope = Data([0x57, 0x53, 0x46, 0x54])
  static let deniedEnvelope = Data([0x57, 0x53, 0x44, 0x4E])
  static let missingEnvelope = Data([0x57, 0x53, 0x4D, 0x53])
  static let blockedEnvelope = Data([0x57, 0x53, 0x42, 0x4C])
  static let unavailableEnvelope = Data([0x57, 0x53, 0x55, 0x4E])
  static let providerFailureEnvelope = Data([0x57, 0x53, 0x50, 0x46])
  static let deadlineEnvelope = Data([0x57, 0x53, 0x44, 0x4C])
  static let blockedReadEnvelope = Data([0x57, 0x53, 0x42, 0x52])
  private let root: URL
  private let deniedRoot: URL
  private let missingRoot: URL
  private let blockedRoot: URL
  private let unavailableRoot: URL
  private let providerFailureRoot: URL
  private let deadlineRoot: URL
  private let blockedReadRoot: URL

  init() {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("workspace-flutter-native-fixture", isDirectory: true)
    deniedRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("workspace-flutter-native-denied", isDirectory: true)
    missingRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("workspace-flutter-native-missing", isDirectory: true)
    blockedRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("workspace-flutter-native-blocked", isDirectory: true)
    unavailableRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("workspace-flutter-native-unavailable")
    providerFailureRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("workspace-flutter-native-provider-failure", isDirectory: true)
    deadlineRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("workspace-flutter-native-deadline", isDirectory: true)
    blockedReadRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("workspace-flutter-native-blocked-read", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: deniedRoot, withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: missingRoot)
    try? FileManager.default.createDirectory(at: blockedRoot, withIntermediateDirectories: true)
    try? Data("not a directory".utf8).write(to: unavailableRoot)
    try? FileManager.default.createDirectory(at: providerFailureRoot, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: deadlineRoot, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: blockedReadRoot, withIntermediateDirectories: true)
    try? Data("native test fixture".utf8).write(to: root.appendingPathComponent("fixture.txt"))
    try? Data("native test cursor fixture".utf8).write(to: root.appendingPathComponent("next.txt"))
    try? Data("deadline fixture".utf8).write(to: deadlineRoot.appendingPathComponent("deadline.txt"))
    try? Data("blocked read fixture".utf8).write(to: blockedReadRoot.appendingPathComponent("blocked.txt"))
  }

  func resolve(_ bookmark: Data) throws -> IOSResolvedBookmark {
    switch bookmark {
    case Self.envelope: return IOSResolvedBookmark(root: root, isStale: false)
    case Self.deniedEnvelope: return IOSResolvedBookmark(root: deniedRoot, isStale: false)
    case Self.missingEnvelope: return IOSResolvedBookmark(root: missingRoot, isStale: false)
    case Self.blockedEnvelope: return IOSResolvedBookmark(root: blockedRoot, isStale: false)
    case Self.unavailableEnvelope: return IOSResolvedBookmark(root: unavailableRoot, isStale: false)
    case Self.providerFailureEnvelope:
      return IOSResolvedBookmark(root: providerFailureRoot, isStale: false)
    case Self.deadlineEnvelope: return IOSResolvedBookmark(root: deadlineRoot, isStale: false)
    case Self.blockedReadEnvelope: return IOSResolvedBookmark(root: blockedReadRoot, isStale: false)
    default: throw IOSRootAccessError.invalidBookmark
    }
  }

  func startAccessing(_ root: URL) -> Bool { root != deniedRoot }

  func stopAccessing(_: URL) {}

  func beforeList(_ root: URL, isCancelled: () -> Bool) throws {
    if root == providerFailureRoot { throw IOSProviderFailure() }
    if root == unavailableRoot { throw IOSProviderUnavailable() }
    if root == deadlineRoot {
      Thread.sleep(forTimeInterval: 0.02)
      return
    }
    guard root == blockedRoot else { return }
    let expiry = ProcessInfo.processInfo.systemUptime + 5
    while !isCancelled() && ProcessInfo.processInfo.systemUptime < expiry {
      Thread.sleep(forTimeInterval: 0.005)
    }
    if !isCancelled() { throw IOSRootAccessError.permissionLost }
  }

  func beforeRead(_ root: URL, isCancelled: () -> Bool) throws {
    guard root == blockedReadRoot else { return }
    let expiry = ProcessInfo.processInfo.systemUptime + 5
    while !isCancelled() && ProcessInfo.processInfo.systemUptime < expiry {
      Thread.sleep(forTimeInterval: 0.005)
    }
    if !isCancelled() { throw IOSRootAccessError.permissionLost }
  }
}
#endif
