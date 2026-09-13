package com.mattsp1290.workspace_flutter.internal

import java.io.IOException
import java.io.InputStream

internal class SequentialOffsetLimitExceeded : IOException()

/** Bounded positioning that works for seekable files and provider-backed pipes. */
internal object ReadPositioning {
  const val maxSequentialOffset = 32L * 1024 * 1024
  /**
   * Returns false when EOF precedes [offset]. [check] is invoked while a
   * non-seekable stream is being discarded, so cancellation/deadlines remain
   * authoritative during a large offset.
   */
  fun position(
    input: InputStream,
    offset: Long,
    trySeek: (Long) -> Unit,
    check: () -> Unit,
  ): Boolean {
    try {
      trySeek(offset)
      return true
    } catch (_: IOException) {
      // SAF providers commonly expose pipes, which cannot seek.
    } catch (_: UnsupportedOperationException) {
      // Fall back to cooperative sequential discard.
    }
    if (offset > maxSequentialOffset) throw SequentialOffsetLimitExceeded()
    var remaining = offset
    val singleByte = ByteArray(1)
    while (remaining > 0) {
      check()
      val skipped = input.skip(remaining)
      if (skipped > 0) {
        remaining -= skipped
        continue
      }
      if (input.read(singleByte) < 0) return false
      remaining -= 1
    }
    return true
  }
}
