import Foundation

/// Engine-owned operation state. The coordinator stays alive until the caller
/// removes this operation after provider cleanup, not merely after a Flutter
/// result has been queued.
internal final class WorkspaceNativeOperation {
  let workspaceId: String
  let engineGeneration: Int
  let coordinator = NSFileCoordinator()
  private let lock = NSLock()
  private var cancelled = false

  init(workspaceId: String, engineGeneration: Int) {
    self.workspaceId = workspaceId
    self.engineGeneration = engineGeneration
  }

  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
    coordinator.cancel()
  }

  func isCancelled() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }
}

/** Thread-safe active-operation registry used by the production plugin and XCTest. */
internal final class WorkspaceOperationRegistry {
  private let cleanupCondition = NSCondition()
  private var active: [String: WorkspaceNativeOperation] = [:]
  private var closingWorkspaces: Set<String> = []

  func register(
    operationId: String,
    workspaceId: String,
    engineGeneration: Int
  ) -> WorkspaceNativeOperation? {
    cleanupCondition.lock()
    defer { cleanupCondition.unlock() }
    guard !closingWorkspaces.contains(workspaceId) else { return nil }
    guard active[operationId] == nil else { return nil }
    let operation = WorkspaceNativeOperation(workspaceId: workspaceId, engineGeneration: engineGeneration)
    active[operationId] = operation
    return operation
  }

  func remove(_ operationId: String) {
    cleanupCondition.lock()
    active.removeValue(forKey: operationId)
    cleanupCondition.broadcast()
    cleanupCondition.unlock()
  }

  func cancel(_ operationId: String) {
    cleanupCondition.lock()
    let operation = active[operationId]
    cleanupCondition.unlock()
    operation?.cancel()
  }

  /// Prevents new work before requesting cancellation of existing work.
  func closeWorkspace(_ workspaceId: String) {
    cleanupCondition.lock()
    closingWorkspaces.insert(workspaceId)
    let matching = active.values.filter { $0.workspaceId == workspaceId }
    cleanupCondition.unlock()
    matching.forEach { $0.cancel() }
  }

  func isWorkspaceClosing(_ workspaceId: String) -> Bool {
    cleanupCondition.lock()
    defer { cleanupCondition.unlock() }
    return closingWorkspaces.contains(workspaceId)
  }

  func cancelAll() {
    cleanupCondition.lock()
    let values = Array(active.values)
    cleanupCondition.unlock()
    values.forEach { $0.cancel() }
  }

  func hasLiveWorkspace(_ workspaceId: String) -> Bool {
    cleanupCondition.lock()
    defer { cleanupCondition.unlock() }
    return active.values.contains { $0.workspaceId == workspaceId }
  }

  /// Called from a background cleanup owner; it never blocks the UI thread.
  func awaitWorkspaceCleanup(_ workspaceId: String) {
    cleanupCondition.lock()
    while active.values.contains(where: { $0.workspaceId == workspaceId }) {
      cleanupCondition.wait()
    }
    cleanupCondition.unlock()
  }

  var activeCount: Int {
    cleanupCondition.lock()
    defer { cleanupCondition.unlock() }
    return active.count
  }
}
