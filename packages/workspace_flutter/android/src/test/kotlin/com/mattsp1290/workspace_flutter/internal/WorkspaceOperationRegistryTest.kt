package com.mattsp1290.workspace_flutter.internal

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class WorkspaceOperationRegistryTest {
  @Test fun `C01 captured body terminal is not replaced by a late cancellation`() {
    val operation = WorkspaceNativeOperation("workspace", 1, requestPlatformCancellation = {})

    assertEquals(null, operation.captureBody(null)?.errorCode)
    operation.cancel()

    assertEquals(null, operation.terminalState()?.errorCode)
  }

  @Test fun `C03 close wins before provider completion`() {
    val operation = WorkspaceNativeOperation("workspace", 1, requestPlatformCancellation = {})

    operation.close()
    assertEquals(null, operation.captureBody(null))
    assertEquals("closed", operation.terminalState()?.errorCode)
  }

  @Test fun `C02 rejects duplicate operation ids without replacing the live operation`() {
    val registry = WorkspaceOperationRegistry()
    val first = registry.register("operation", "one", 1)

    assertNotNull(first)
    assertNull(registry.register("operation", "two", 1))
    assertEquals(1, registry.activeCount)
    assertTrue(registry.hasLiveWorkspace("one"))
    assertFalse(registry.hasLiveWorkspace("two"))
  }

  @Test fun `C03 only cancels matching workspace operations until their cleanup is removed`() {
    val registry = WorkspaceOperationRegistry { workspaceId, generation ->
      WorkspaceNativeOperation(
        workspaceId = workspaceId,
        engineGeneration = generation,
        requestPlatformCancellation = {},
      )
    }
    val one = requireNotNull(registry.register("one", "workspace-one", 1))
    val two = requireNotNull(registry.register("two", "workspace-two", 1))

    registry.closeWorkspace("workspace-one")

    assertTrue(one.isCancelled())
    assertFalse(two.isCancelled())
    assertTrue(registry.hasLiveWorkspace("workspace-one"))
    registry.remove("one", one)
    assertFalse(registry.hasLiveWorkspace("workspace-one"))
    assertTrue(registry.hasLiveWorkspace("workspace-two"))
  }

  @Test fun `C03 closing a workspace prevents late operation registration`() {
    val registry = WorkspaceOperationRegistry()

    registry.closeWorkspace("workspace")

    assertTrue(registry.isWorkspaceClosing("workspace"))
    assertNull(registry.register("late", "workspace", 1))
  }
  @Test fun `C03 cleanup barrier waits for a held matching operation`() {
    val registry = WorkspaceOperationRegistry()
    val operation = requireNotNull(registry.register("one", "workspace", 1))
    val waiting = CountDownLatch(1)
    val released = CountDownLatch(1)
    val waiter = Thread {
      waiting.countDown()
      registry.awaitWorkspaceCleanup("workspace")
      released.countDown()
    }

    waiter.start()
    assertTrue(waiting.await(1, TimeUnit.SECONDS))
    assertFalse(released.await(50, TimeUnit.MILLISECONDS))
    registry.remove("one", operation)
    assertTrue(released.await(1, TimeUnit.SECONDS))
    waiter.join(1_000)
  }
}
