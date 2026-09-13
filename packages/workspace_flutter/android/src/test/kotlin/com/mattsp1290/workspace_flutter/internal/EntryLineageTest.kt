package com.mattsp1290.workspace_flutter.internal

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class EntryLineageTest {
  @Test fun `P08 preserves opaque parent lineage through the private codec`() {
    val record = EntryRecord(parentId = "root", documentId = "provider/document")
    assertEquals(record, EntryLineage.decode(EntryLineage.encode(record)))
  }

  @Test fun `P08 rejects a cycle or a root mismatch`() {
    val cyclic = mapOf(
      "root" to EntryRecord(null, "root-document"),
      "a" to EntryRecord("b", "a-document"),
      "b" to EntryRecord("a", "b-document"),
    )
    assertNull(EntryLineage.resolve("a", "root-document", cyclic::get))
    assertNull(EntryLineage.resolve("root", "other-root", cyclic::get))
  }
}
