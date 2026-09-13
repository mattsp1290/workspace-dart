package com.mattsp1290.workspace_flutter.internal

import org.junit.Assert.assertEquals
import org.junit.Test

class AndroidProviderResourceCountersTest {
  @Test fun `P11 tracks query and descriptor resources independently`() {
    val counters = AndroidProviderResourceCounters()

    val query = counters.acquireQuery()
    val read = counters.acquireReadHandle()
    assertEquals(1, counters.activeQueries)
    assertEquals(1, counters.activeReadHandles)
    assertEquals(2, counters.activeTotal)

    query.close()
    read.close()
    assertEquals(0, counters.activeTotal)
  }

  @Test fun `P11 rejects a duplicate lease close`() {
    val lease = AndroidProviderResourceCounters().acquireQuery()
    lease.close()

    try {
      lease.close()
      throw AssertionError("expected duplicate close to fail")
    } catch (_: IllegalStateException) {
      // The checked token prevents an underflow from hiding a resource leak.
    }
  }
}
