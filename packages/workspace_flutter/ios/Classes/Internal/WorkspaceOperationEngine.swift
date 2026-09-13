import Foundation

/**
 Owns operation registration, background scheduling, cleanup barriers, and
 generation-fenced main-thread settlement. Channel handlers provide protocol
 validation and provider work, then translate only the terminal wire payload.
 */
internal final class WorkspaceOperationEngine {
  private let registry = WorkspaceOperationRegistry()
  private let stateLock = NSLock()
  private var generation = 0
  private var detached = false

  func run(
    operationId: String,
    workspaceId: String,
    remainingMillis: Int64,
    settle: @escaping (WorkspaceNativeOperation, Result<Any, Error>) -> Void,
    body: @escaping (WorkspaceNativeOperation, TimeInterval) throws -> Any
  ) -> Bool {
    stateLock.lock()
    let currentGeneration = generation
    let isDetached = detached
    stateLock.unlock()
    guard !isDetached,
          let operation = registry.register(
            operationId: operationId,
            workspaceId: workspaceId,
            engineGeneration: currentGeneration
          ) else { return false }

    let deadline = ProcessInfo.processInfo.systemUptime + Double(remainingMillis) / 1000.0
    DispatchQueue.global(qos: .userInitiated).async {
      let bodyTerminal: Result<Any, Error>
      do {
        bodyTerminal = .success(try body(operation, deadline))
      } catch {
        bodyTerminal = .failure(error)
      }
      let terminal = operation.captureBody(bodyTerminal)
      DispatchQueue.main.async {
        defer { self.registry.remove(operationId) }
        guard self.canSettle(operation) else { return }
        settle(operation, terminal)
      }
    }
    return true
  }

  func cancel(_ operationId: String) { registry.cancel(operationId) }

  func closeWorkspace(_ workspaceId: String) { registry.closeWorkspace(workspaceId) }

  func isWorkspaceClosing(_ workspaceId: String) -> Bool {
    registry.isWorkspaceClosing(workspaceId)
  }

  func afterWorkspaceCleanup(_ workspaceId: String, _ cleanup: @escaping () -> Void) {
    DispatchQueue.global(qos: .userInitiated).async {
      self.registry.awaitWorkspaceCleanup(workspaceId)
      cleanup()
    }
  }

  func detach() {
    stateLock.lock()
    detached = true
    generation += 1
    stateLock.unlock()
    registry.cancelAll()
  }

  private func canSettle(_ operation: WorkspaceNativeOperation) -> Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return !detached && operation.engineGeneration == generation
  }
}
