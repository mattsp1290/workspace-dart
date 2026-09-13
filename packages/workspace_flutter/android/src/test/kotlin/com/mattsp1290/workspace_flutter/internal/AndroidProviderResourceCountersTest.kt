package com.mattsp1290.workspace_flutter.internal

import org.junit.Assert.assertEquals
import org.junit.Test

class AndroidProviderResourceCountersTest {
  @Test fun `P11 tracks query and descriptor resources independently`() {
    val counters = AndroidProviderResourceCounters()

    counters.openedQuery()
    counters.openedReadHandle()
    assertEquals(1, counters.activeQueries)
    assertEquals(1, counters.activeReadHandles)
    assertEquals(2, counters.activeTotal)

    counters.closedQuery()
    counters.closedReadHandle()
    assertEquals(0, counters.activeTotal)
  }
}
