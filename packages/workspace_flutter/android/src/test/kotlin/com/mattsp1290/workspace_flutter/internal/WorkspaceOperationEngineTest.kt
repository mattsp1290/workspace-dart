package com.mattsp1290.workspace_flutter.internal

import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class WorkspaceOperationEngineTest {
  @Test fun `C01 cancellation wins when work reaches its terminal callback`() {
    val engine = WorkspaceOperationEngine()
    val entered = CountDownLatch(1)
    val release = CountDownLatch(1)
    val settled = CountDownLatch(1)
    var errorCode: String? = null

    assertTrue(engine.run(
      operationId = "cancelled-operation",
      workspaceId = "workspace",
      remainingMillis = 1_000,
      result = recordingResult(
        error = {
          errorCode = it
          settled.countDown()
        },
      ),
    ) { operation, _ ->
      entered.countDown()
      assertTrue(release.await(1, TimeUnit.SECONDS))
      if (operation.isCancelled()) throw WorkspaceOperationFailure("providerFailure")
      "unexpected"
    })
    assertTrue(entered.await(1, TimeUnit.SECONDS))
    engine.cancel("cancelled-operation")
    release.countDown()

    repeat(20) {
      Shadows.shadowOf(android.os.Looper.getMainLooper()).idle()
      if (settled.await(10, TimeUnit.MILLISECONDS)) return@repeat
    }
    assertEquals("cancelled", errorCode)
  }

  @Test fun `C02 rejects a duplicate ID and settles the original exactly once`() {
    val engine = WorkspaceOperationEngine()
    val entered = CountDownLatch(1)
    val release = CountDownLatch(1)
    val settled = CountDownLatch(1)
    var successes = 0

    assertTrue(engine.run(
      operationId = "operation",
      workspaceId = "workspace",
      remainingMillis = 1_000,
      result = recordingResult(
        success = {
          successes += 1
          settled.countDown()
        },
      ),
    ) { _, _ ->
      entered.countDown()
      assertTrue(release.await(1, TimeUnit.SECONDS))
      "complete"
    })
    assertTrue(entered.await(1, TimeUnit.SECONDS))

    assertFalse(engine.run(
      operationId = "operation",
      workspaceId = "other-workspace",
      remainingMillis = 1_000,
      result = recordingResult(),
    ) { _, _ -> "unexpected" })

    release.countDown()
    repeat(20) {
      Shadows.shadowOf(android.os.Looper.getMainLooper()).idle()
      if (settled.await(10, TimeUnit.MILLISECONDS)) return@repeat
    }
    assertEquals(1, successes)
  }

  @Test fun `C03 detach fences a late callback and a new generation can run`() {
    val engine = WorkspaceOperationEngine()
    val entered = CountDownLatch(1)
    val release = CountDownLatch(1)
    val staleReplies = AtomicInteger()

    assertTrue(engine.run(
      operationId = "stale-operation",
      workspaceId = "workspace",
      remainingMillis = 1_000,
      result = recordingResult(
        success = { staleReplies.incrementAndGet() },
        error = { staleReplies.incrementAndGet() },
      ),
    ) { _, _ ->
      entered.countDown()
      assertTrue(release.await(1, TimeUnit.SECONDS))
      "late"
    })
    assertTrue(entered.await(1, TimeUnit.SECONDS))
    engine.detach()
    release.countDown()
    repeat(20) {
      Shadows.shadowOf(android.os.Looper.getMainLooper()).idle()
      Thread.sleep(5)
    }
    assertEquals(0, staleReplies.get())
    assertFalse(engine.run(
      operationId = "while-detached",
      workspaceId = "workspace",
      remainingMillis = 1_000,
      result = recordingResult(),
    ) { _, _ -> "unexpected" })

    engine.attach()
    val freshSettled = CountDownLatch(1)
    assertTrue(engine.run(
      operationId = "fresh-operation",
      workspaceId = "fresh-workspace",
      remainingMillis = 1_000,
      result = recordingResult(success = { freshSettled.countDown() }),
    ) { _, _ -> "fresh" })
    repeat(20) {
      Shadows.shadowOf(android.os.Looper.getMainLooper()).idle()
      if (freshSettled.await(10, TimeUnit.MILLISECONDS)) return@repeat
    }
    assertEquals(0L, freshSettled.count)
  }

  private fun recordingResult(
    success: () -> Unit = {},
    error: (String) -> Unit = { throw AssertionError("unexpected native error: $it") },
  ): MethodChannel.Result =
    object : MethodChannel.Result {
      override fun success(result: Any?) = success()
      override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) =
        error(errorCode)
      override fun notImplemented() = throw AssertionError("unexpected notImplemented")
    }
}
