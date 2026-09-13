package com.mattsp1290.workspace_flutter.internal

import java.util.concurrent.Callable
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * One plugin-owned state lane for short durable-state transitions. Provider
 * I/O must never run here; callers enumerate/read first and re-enter only to
 * validate or commit private state. Re-entrancy avoids deadlock in composite
 * transitions that call another state helper.
 */
internal class WorkspaceStateExecutor {
  private val owner = ThreadLocal<Boolean>()
  private var executor: ExecutorService = Executors.newSingleThreadExecutor()

  @Synchronized fun attach() {
    if (executor.isShutdown) executor = Executors.newSingleThreadExecutor()
  }

  fun <T> call(block: () -> T): T {
    if (owner.get() == true) return block()
    return executor.submit(Callable {
      owner.set(true)
      try {
        block()
      } finally {
        owner.remove()
      }
    }).get()
  }

  @Synchronized fun close() {
    // A detached engine must not drain queued lineage commits after its
    // operation generation has been fenced.
    executor.shutdownNow()
  }
}
