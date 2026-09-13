package com.mattsp1290.workspace_flutter.internal

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

@RunWith(RobolectricTestRunner::class)
class AndroidGrantStoreTest {
  @Test fun `P04 promotes a complete authority-bound acquisition`() {
    val context = RuntimeEnvironment.getApplication()
    clear(context)
    val store = AndroidGrantStore(context)
    val digest = ByteArray(32) { 7 }

    assertTrue(store.writeAcquisition(
      "workspace", "content://authority/tree/root", "acquired", true, 9,
      "abcdefghijklmnopqrstuv", digest,
    ))
    assertTrue(store.promoteAcquisition("workspace"))

    val active = requireNotNull(store.active("workspace"))
    assertEquals("active", active.phase)
    assertTrue(active.owned)
    assertEquals(9, active.generation)
    assertEquals("abcdefghijklmnopqrstuv", active.rootId)
    assertArrayEquals(digest, active.digest)
    assertNull(store.acquisition("workspace"))
    clear(context)
  }

  @Test fun `P04 rejects legacy or incomplete active authority state`() {
    val context = RuntimeEnvironment.getApplication()
    clear(context)
    context.getSharedPreferences(storeName, 0).edit()
      .putString("active:workspace:uri", "content://authority/tree/root")
      .putBoolean("active:workspace:owned", true)
      .commit()
    val store = AndroidGrantStore(context)

    assertTrue(store.hasActiveState("workspace"))
    assertNull(store.active("workspace"))
    assertFalse(store.ensureRestoredActive("workspace", record()))
    assertTrue(store.clearActive("workspace"))
    assertFalse(store.hasActiveState("workspace"))
    clear(context)
  }

  @Test fun `P04 restores only matching canonical authority`() {
    val context = RuntimeEnvironment.getApplication()
    clear(context)
    val store = AndroidGrantStore(context)
    val record = record()

    assertTrue(store.ensureRestoredActive("workspace", record))
    assertTrue(store.ensureRestoredActive("workspace", record))
    assertFalse(store.ensureRestoredActive("workspace", record.copy(generation = 2)))
    clear(context)
  }

  @Test fun `deletion survives a crash boundary and transfers duplicate ownership atomically`() {
    val context = RuntimeEnvironment.getApplication()
    clear(context)
    val store = AndroidGrantStore(context)
    val first = record().copy(owned = true)
    val second = record().copy(rootId = "bcdefghijklmnopqrstuvA")

    assertTrue(store.writeAcquisition(
      "first", first.uri, "acquired", first.owned, first.generation, first.rootId, first.digest,
    ))
    assertTrue(store.promoteAcquisition("first"))
    assertTrue(store.writeAcquisition(
      "second", second.uri, "acquired", second.owned, second.generation, second.rootId, second.digest,
    ))
    assertTrue(store.promoteAcquisition("second"))

    val deleting = requireNotNull(store.beginDeletion("first", "second"))
    assertEquals(first.uri, deleting.uri)
    assertTrue(deleting.owned)
    assertNull(store.active("first"))
    assertEquals("deleting", requireNotNull(store.deleting("first")).phase)
    assertTrue(requireNotNull(store.active("second")).owned)
    assertTrue(store.clearDeleting("first"))
    assertNull(store.deleting("first"))
    clear(context)
  }

  @Test fun `legacy cleanup stages exact prototype records before retiring them`() {
    val context = RuntimeEnvironment.getApplication()
    clear(context)
    val preferences = context.getSharedPreferences(storeName, 0)
    preferences.edit()
      .putString("acq:legacy:uri", "content://authority/tree/root")
      .putString("acq:legacy:phase", "acquired")
      .putBoolean("acq:legacy:owned", true)
      .commit()
    val store = AndroidGrantStore(context)

    val cleanup = requireNotNull(store.stageLegacyCleanup()).single()
    assertEquals("content://authority/tree/root", cleanup.uri)
    assertTrue(cleanup.owned)
    assertTrue(preferences.contains("acq:legacy:uri"))
    // A process death after the durable tombstone and before release must
    // surface the same cleanup intent to the replacement plugin instance.
    val recovered = requireNotNull(AndroidGrantStore(context).stageLegacyCleanup()).single()
    assertEquals(cleanup.key, recovered.key)
    assertEquals(cleanup.uri, recovered.uri)
    assertTrue(recovered.owned)
    assertTrue(AndroidGrantStore(context).finishLegacyCleanup(recovered))
    assertFalse(preferences.contains("acq:legacy:uri"))
    assertTrue(requireNotNull(store.stageLegacyCleanup()).isEmpty())
    clear(context)
  }

  @Test fun `legacy cleanup never interprets a versioned acquisition as legacy`() {
    val context = RuntimeEnvironment.getApplication()
    clear(context)
    val store = AndroidGrantStore(context)
    val record = record()

    assertTrue(store.writeAcquisition(
      "workspace", record.uri, "acquired", true, record.generation, record.rootId, record.digest,
    ))
    assertTrue(requireNotNull(store.stageLegacyCleanup()).isEmpty())
    assertTrue(requireNotNull(store.acquisition("workspace")).owned)
    clear(context)
  }

  @Test fun `legacy cleanup retains malformed records and marks external grants non-owned`() {
    val context = RuntimeEnvironment.getApplication()
    clear(context)
    val preferences = context.getSharedPreferences(storeName, 0)
    preferences.edit()
      .putString("active:external:uri", "content://authority/tree/external")
      .putBoolean("active:external:owned", false)
      .putString("acq:malformed:uri", "content://authority/tree/malformed")
      .commit()
    val store = AndroidGrantStore(context)

    val cleanup = requireNotNull(store.stageLegacyCleanup()).single()
    assertFalse(cleanup.owned)
    assertEquals("content://authority/tree/external", cleanup.uri)
    assertTrue(store.finishLegacyCleanup(cleanup))
    assertFalse(preferences.contains("active:external:uri"))
    assertTrue(preferences.contains("acq:malformed:uri"))
    clear(context)
  }

  @Test fun `durable transitions fail closed when their commit is rejected`() {
    val context = RuntimeEnvironment.getApplication()
    clear(context)
    val record = record()
    val normal = AndroidGrantStore(context)
    val failing = AndroidGrantStore(context) { false }

    assertFalse(failing.writeAcquisition(
      "write", record.uri, "acquired", true, record.generation, record.rootId, record.digest,
    ))
    assertNull(normal.acquisition("write"))

    assertTrue(normal.writeAcquisition(
      "promote", record.uri, "acquired", true, record.generation, record.rootId, record.digest,
    ))
    assertFalse(failing.promoteAcquisition("promote"))
    assertNull(normal.active("promote"))
    assertTrue(requireNotNull(normal.acquisition("promote")).owned)

    assertTrue(normal.promoteAcquisition("promote"))
    assertNull(failing.beginDeletion("promote", null))
    assertTrue(requireNotNull(normal.active("promote")).owned)
    assertNull(normal.deleting("promote"))
    clear(context)
  }

  @Test fun `legacy tombstone stage and retirement preserve retry state on commit failure`() {
    val context = RuntimeEnvironment.getApplication()
    clear(context)
    val preferences = context.getSharedPreferences(storeName, 0)
    preferences.edit()
      .putString("active:legacy:uri", "content://authority/tree/root")
      .putBoolean("active:legacy:owned", true)
      .commit()
    val failing = AndroidGrantStore(context) { false }
    val normal = AndroidGrantStore(context)

    assertNull(failing.stageLegacyCleanup())
    assertTrue(preferences.contains("active:legacy:uri"))
    val staged = requireNotNull(normal.stageLegacyCleanup()).single()
    assertFalse(failing.finishLegacyCleanup(staged))
    assertTrue(preferences.contains("active:legacy:uri"))
    val recovered = requireNotNull(normal.stageLegacyCleanup()).single()
    assertEquals(staged.key, recovered.key)
    assertTrue(normal.finishLegacyCleanup(recovered))
    assertFalse(preferences.contains("active:legacy:uri"))
    clear(context)
  }

  private fun record() = AndroidAcquisitionRecord(
    uri = "content://authority/tree/root",
    phase = "active",
    owned = false,
    generation = 1,
    rootId = "abcdefghijklmnopqrstuv",
    digest = ByteArray(32),
  )

  private companion object {
    const val storeName = "workspace_flutter_grants"

    fun clear(context: android.content.Context) {
      context.getSharedPreferences(storeName, 0).edit().clear().commit()
    }
  }
}
