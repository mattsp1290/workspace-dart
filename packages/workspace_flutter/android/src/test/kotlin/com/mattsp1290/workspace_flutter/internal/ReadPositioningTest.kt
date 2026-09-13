package com.mattsp1290.workspace_flutter.internal

import java.io.ByteArrayInputStream
import java.io.IOException
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class ReadPositioningTest {
  @Test fun `P11 discards a non-seekable prefix cooperatively`() {
    val input = ByteArrayInputStream(byteArrayOf(10, 11, 12, 13))
    var checks = 0

    val positioned = ReadPositioning.position(
      input = input,
      offset = 2,
      trySeek = { throw IOException("pipe") },
      check = { checks += 1 },
    )

    assertTrue(positioned)
    assertTrue(checks > 0)
    assertArrayEquals(byteArrayOf(12, 13), input.readBytes())
  }

  @Test fun `P11 reports eof before a non-seekable offset`() {
    val input = ByteArrayInputStream(byteArrayOf(10))

    val positioned = ReadPositioning.position(
      input = input,
      offset = 2,
      trySeek = { throw UnsupportedOperationException() },
      check = {},
    )

    assertFalse(positioned)
  }

  @Test fun `P11 caps only the non-seekable offset fallback`() {
    try {
      ReadPositioning.position(
        input = ByteArrayInputStream(byteArrayOf()),
        offset = ReadPositioning.maxSequentialOffset + 1,
        trySeek = { throw IOException("pipe") },
        check = {},
      )
      fail("Expected the sequential cap to reject the offset")
    } catch (_: SequentialOffsetLimitExceeded) {
      // Expected.
    }
  }
}
