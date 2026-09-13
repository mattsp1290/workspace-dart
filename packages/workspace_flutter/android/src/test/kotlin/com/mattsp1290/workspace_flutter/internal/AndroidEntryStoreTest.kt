package com.mattsp1290.workspace_flutter.internal

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

@RunWith(RobolectricTestRunner::class)
class AndroidEntryStoreTest {
  @Test fun `P04 persists a versioned root authority record`() {
    val context = RuntimeEnvironment.getApplication()
    clear(context)
    val store = AndroidEntryStore(context)
    val record = AndroidRootRecord(
      documentId = "root-document",
      generation = 7,
      rootId = "abcdefghijklmnopqrstuv",
      digest = ByteArray(32) { 9 },
    )

    assertTrue(store.bindRoot("workspace", record))
    val restored = requireNotNull(store.rootRecord("workspace"))
    assertTrue(store.hasRootState("workspace"))
    assertTrue(store.bindRoot("workspace", record))
    assertTrue(restored.documentId == record.documentId && restored.generation == record.generation)
    assertTrue(restored.rootId == record.rootId)
    assertArrayEquals(record.digest, restored.digest)
    clear(context)
  }

  @Test fun `P04 rejects unversioned root authority state`() {
    val context = RuntimeEnvironment.getApplication()
    clear(context)
    context.getSharedPreferences(storeName, 0).edit()
      .putString("root-binding:workspace", "legacy-root-document")
      .commit()
    val store = AndroidEntryStore(context)

    assertTrue(store.hasRootState("workspace"))
    assertNull(store.rootRecord("workspace"))
    assertFalse(store.bindRoot("workspace", AndroidRootRecord(
      documentId = "root-document", generation = 1, rootId = "abcdefghijklmnopqrstuv", digest = ByteArray(32),
    )))
    clear(context)
  }

  private companion object {
    const val storeName = "workspace_flutter_entries"

    fun clear(context: android.content.Context) {
      context.getSharedPreferences(storeName, 0).edit().clear().commit()
    }
  }
}
