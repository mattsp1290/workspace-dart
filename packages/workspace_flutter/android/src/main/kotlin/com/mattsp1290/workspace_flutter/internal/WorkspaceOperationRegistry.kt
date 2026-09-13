package com.mattsp1290.workspace_flutter.internal

import android.os.CancellationSignal
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/** The first transition is authoritative; platform cancellation stays cooperative. */
internal data class WorkspaceTerminalState(val errorCode: String?)

/** Engine-owned cancellation and cleanup identity for one native operation. */
internal class WorkspaceNativeOperation(
  val workspaceId: String,
  val engineGeneration: Long,
  val cancellation: CancellationSignal = CancellationSignal(),
  private val requestPlatformCancellation: () -> Unit = { cancellation.cancel() },
) {
  val settled = AtomicBoolean(false)
  private val cancellationRequested = AtomicBoolean(false)
  private val terminal = AtomicReference<WorkspaceTerminalState?>(null)

  fun cancel() {
    claimTerminal("cancelled")
    if (cancellationRequested.compareAndSet(false, true)) requestPlatformCancellation()
  }

  fun close() {
    claimTerminal("closed")
    if (cancellationRequested.compareAndSet(false, true)) requestPlatformCancellation()
  }

  /** Captures a provider result only when no earlier terminal event won. */
  fun captureBody(errorCode: String?): WorkspaceTerminalState? {
    val captured = WorkspaceTerminalState(errorCode)
    return if (terminal.compareAndSet(null, captured)) captured else null
  }

  fun terminalState(): WorkspaceTerminalState? = terminal.get()

  private fun claimTerminal(errorCode: String) {
    terminal.compareAndSet(null, WorkspaceTerminalState(errorCode))
  }

  /** The engine only exposes this signal to providers; it owns cancellation. */
  fun isCancelled(): Boolean = cancellationRequested.get()
}

/**
 * Thread-safe active-operation registry. Cleanup remains owned by the caller
 * until [remove] succeeds, which is what makes workspace close barriers
 * independent of MethodChannel result delivery.
 */
internal class WorkspaceOperationRegistry(
  private val operationFactory: (String, Long) -> WorkspaceNativeOperation =
    { workspaceId, generation -> WorkspaceNativeOperation(workspaceId, generation) },
) {
  private val active = ConcurrentHashMap<String, WorkspaceNativeOperation>()
  @Suppress("PLATFORM_CLASS_MAPPED_TO_KOTLIN")
  private val cleanupMonitor = java.lang.Object()
  private val closingWorkspaces = ConcurrentHashMap.newKeySet<String>()

  fun register(
    operationId: String,
    workspaceId: String,
    engineGeneration: Long,
  ): WorkspaceNativeOperation? {
    val operation = operationFactory(workspaceId, engineGeneration)
    synchronized(cleanupMonitor) {
      if (workspaceId in closingWorkspaces) return null
      return if (active.putIfAbsent(operationId, operation) == null) operation else null
    }
  }

  fun remove(operationId: String, operation: WorkspaceNativeOperation) {
    synchronized(cleanupMonitor) {
      active.remove(operationId, operation)
      cleanupMonitor.notifyAll()
    }
  }

  fun cancel(operationId: String) {
    active[operationId]?.cancel()
  }

  /** Prevents new work before requesting cancellation of existing work. */
  fun closeWorkspace(workspaceId: String) {
    closingWorkspaces.add(workspaceId)
    active.values.filter { it.workspaceId == workspaceId }.forEach { it.close() }
  }

  fun isWorkspaceClosing(workspaceId: String): Boolean = workspaceId in closingWorkspaces

  fun cancelAll() {
    active.values.forEach { it.cancel() }
  }

  fun hasLiveWorkspace(workspaceId: String): Boolean =
    active.values.any { it.workspaceId == workspaceId }

  /** Blocks only a background cleanup owner until matching work is released. */
  fun awaitWorkspaceCleanup(workspaceId: String) {
    synchronized(cleanupMonitor) {
      while (hasLiveWorkspace(workspaceId)) cleanupMonitor.wait()
    }
  }

  val activeCount: Int get() = active.size
}
