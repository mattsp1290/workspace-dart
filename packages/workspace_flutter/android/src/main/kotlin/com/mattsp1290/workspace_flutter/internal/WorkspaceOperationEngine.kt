package com.mattsp1290.workspace_flutter.internal

import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.flutter.plugin.common.MethodChannel
import java.io.FileNotFoundException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/** Typed failures deliberately contain only wire-safe error codes. */
internal open class WorkspaceOperationFailure(val code: String) : RuntimeException()

/**
 * Owns native worker scheduling, once-only result settlement, cancellation,
 * and cleanup barriers. Channel handlers provide validation and provider work
 * only; they never own a worker or an active operation directly.
 */
internal class WorkspaceOperationEngine(
  private val main: Handler = Handler(Looper.getMainLooper()),
) {
  private var workers: ExecutorService = Executors.newCachedThreadPool()
  private val operations = WorkspaceOperationRegistry()
  private val detached = AtomicBoolean(false)
  private val generation = AtomicLong(0)

  fun attach() {
    generation.incrementAndGet()
    detached.set(false)
    if (workers.isShutdown) workers = Executors.newCachedThreadPool()
  }

  fun detach() {
    operations.cancelAll()
    detached.set(true)
    generation.incrementAndGet()
    workers.shutdown()
  }

  fun run(
    operationId: String,
    workspaceId: String,
    remainingMillis: Long,
    result: MethodChannel.Result,
    body: (WorkspaceNativeOperation, Long) -> Any,
  ): Boolean {
    if (detached.get()) return false
    val operation = operations.register(operationId, workspaceId, generation.get()) ?: return false
    if (detached.get() || operation.engineGeneration != generation.get()) {
      operations.remove(operationId, operation)
      return false
    }
    val deadline = SystemClock.elapsedRealtime() + remainingMillis
    try {
      workers.execute {
        try {
          finish(operationId, operation, result, value = body(operation, deadline))
        } catch (error: Throwable) {
          val code = when {
            operation.isCancelled() -> "cancelled"
            error is WorkspaceOperationFailure -> error.code
            error is AndroidProviderUnavailable -> "unavailable"
            error is FileNotFoundException -> "notFound"
            error is SecurityException -> "permissionLost"
            else -> "providerFailure"
          }
          finish(operationId, operation, result, errorCode = code)
        }
      }
    } catch (_: RejectedExecutionException) {
      operations.remove(operationId, operation)
      return false
    }
    return true
  }

  fun cancel(operationId: String) = operations.cancel(operationId)

  fun closeWorkspace(workspaceId: String) = operations.closeWorkspace(workspaceId)

  fun isWorkspaceClosing(workspaceId: String): Boolean = operations.isWorkspaceClosing(workspaceId)

  fun afterWorkspaceCleanup(workspaceId: String, cleanup: () -> Unit) {
    workers.execute {
      operations.awaitWorkspaceCleanup(workspaceId)
      cleanup()
    }
  }

  fun postToMain(callback: () -> Unit) = main.post(callback)

  private fun finish(
    operationId: String,
    operation: WorkspaceNativeOperation,
    result: MethodChannel.Result,
    value: Any? = null,
    errorCode: String? = null,
  ) {
    if (!operation.settled.compareAndSet(false, true)) return
    if (detached.get() || operation.engineGeneration != generation.get()) {
      operations.remove(operationId, operation)
      return
    }
    main.post {
      try {
        if (detached.get() || operation.engineGeneration != generation.get()) return@post
        when {
          operation.isCancelled() -> result.error("cancelled", null, null)
          errorCode != null -> result.error(errorCode, null, null)
          else -> result.success(value)
        }
      } finally {
        operations.remove(operationId, operation)
      }
    }
  }
}
