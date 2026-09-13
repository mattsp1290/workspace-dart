package com.mattsp1290.workspace_flutter.internal

import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class WorkspaceStateExecutorTest {
  @Test fun `state work is serialized and can re-enter the owning lane`() {
    val state = WorkspaceStateExecutor()
    val callers = Executors.newFixedThreadPool(4)
    val finished = CountDownLatch(8)
    val active = AtomicInteger()
    val maximum = AtomicInteger()
    val values = mutableListOf<Int>()

    repeat(8) { index ->
      callers.execute {
        state.call {
          maximum.updateAndGet { maxOf(it, active.incrementAndGet()) }
          try {
            values += state.call { index }
          } finally {
            active.decrementAndGet()
            finished.countDown()
          }
        }
      }
    }

    assertEquals(true, finished.await(2, TimeUnit.SECONDS))
    assertEquals(1, maximum.get())
    assertEquals((0 until 8).toSet(), values.toSet())
    callers.shutdownNow()
    state.close()
  }

  @Test fun `closed state lane rejects late commits`() {
    val state = WorkspaceStateExecutor()
    state.close()

    try {
      state.call { "late" }
      fail("closed state lane accepted late work")
    } catch (_: RejectedExecutionException) {
      // Expected: detach closes the lane before any later state commit.
    }
  }

  @Test fun `attach creates a fresh lane after detach`() {
    val state = WorkspaceStateExecutor()
    state.close()
    state.attach()

    assertEquals("fresh", state.call { "fresh" })
    state.close()
  }
}
