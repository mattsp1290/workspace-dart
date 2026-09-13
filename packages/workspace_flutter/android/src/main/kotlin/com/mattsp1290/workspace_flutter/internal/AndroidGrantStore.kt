package com.mattsp1290.workspace_flutter.internal

import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import java.security.MessageDigest

internal data class AndroidAcquisitionRecord(
  val uri: String,
  val phase: String,
  val owned: Boolean,
  val generation: Long,
  val rootId: String,
  val digest: ByteArray,
)

/** A durable release intent for one exact-schema pre-v1 grant group. */
internal data class AndroidLegacyCleanupRecord(
  val key: String,
  val uri: String,
  val owned: Boolean,
)

/** Durable private journal for Android tree-permission acquisition state. */
internal class AndroidGrantStore(
  context: Context,
  private val commit: (SharedPreferences.Editor) -> Boolean = { it.commit() },
) {
  private val store = context.getSharedPreferences(STORE_NAME, Context.MODE_PRIVATE)

  fun writeAcquisition(
    workspaceId: String,
    uri: String,
    phase: String,
    owned: Boolean,
    generation: Long,
    rootId: String,
    digest: ByteArray,
  ): Boolean = commit(
    store.edit()
      .putString("acq:$workspaceId:uri", uri)
      .putString("acq:$workspaceId:phase", phase)
      .putBoolean("acq:$workspaceId:owned", owned)
      .putLong("acq:$workspaceId:generation", generation)
      .putString("acq:$workspaceId:rootId", rootId)
      .putString("acq:$workspaceId:digest", encodeDigest(digest)),
  )

  fun clearAcquisition(workspaceId: String): Boolean = commit(store.edit()
    .remove("acq:$workspaceId:uri")
    .remove("acq:$workspaceId:phase")
    .remove("acq:$workspaceId:owned")
    .remove("acq:$workspaceId:generation")
    .remove("acq:$workspaceId:rootId")
    .remove("acq:$workspaceId:digest"))

  fun acquisition(workspaceId: String): AndroidAcquisitionRecord? {
    return record("acq:$workspaceId")
  }

  fun active(workspaceId: String): AndroidAcquisitionRecord? = record("active:$workspaceId")

  fun hasActiveState(workspaceId: String): Boolean =
    store.all.keys.any { it.startsWith("active:$workspaceId:") }

  fun clearActive(workspaceId: String): Boolean = clear("active:$workspaceId")

  fun deleting(workspaceId: String): AndroidAcquisitionRecord? = record("deleting:$workspaceId")

  fun clearDeleting(workspaceId: String): Boolean = clear("deleting:$workspaceId")

  /**
   * Atomically fences a lease from new operations before any potentially
   * fallible SAF release. A replacement lease may inherit ownership in the
   * same commit, so a later crash cannot leave the shared grant ownerless.
   */
  fun beginDeletion(workspaceId: String, replacementWorkspaceId: String?): AndroidAcquisitionRecord? {
    val active = active(workspaceId) ?: return null
    val replacement = replacementWorkspaceId?.let(::active)
    if (replacementWorkspaceId != null && (replacement == null || replacement.uri != active.uri)) return null
    val editor = store.edit()
      .putString("deleting:$workspaceId:uri", active.uri)
      .putString("deleting:$workspaceId:phase", "deleting")
      .putBoolean("deleting:$workspaceId:owned", active.owned)
      .putLong("deleting:$workspaceId:generation", active.generation)
      .putString("deleting:$workspaceId:rootId", active.rootId)
      .putString("deleting:$workspaceId:digest", encodeDigest(active.digest))
      .remove("active:$workspaceId:uri")
      .remove("active:$workspaceId:phase")
      .remove("active:$workspaceId:owned")
      .remove("active:$workspaceId:generation")
      .remove("active:$workspaceId:rootId")
      .remove("active:$workspaceId:digest")
    if (active.owned && replacementWorkspaceId != null) {
      editor.putBoolean("active:$replacementWorkspaceId:owned", true)
    }
    return active.takeIf { commit(editor) }
  }

  fun ensureRestoredActive(workspaceId: String, record: AndroidAcquisitionRecord): Boolean {
    val existing = active(workspaceId)
    if (existing != null) return sameAuthority(existing, record)
    if (store.contains("active:$workspaceId:uri")) return false
    return writeActive(workspaceId, record)
  }

  /** Atomically promotes an acquisition without changing its ownership bit. */
  fun promoteAcquisition(workspaceId: String): Boolean {
    if (store.contains("active:$workspaceId:uri")) return clearAcquisition(workspaceId)
    val acquisition = acquisition(workspaceId) ?: return false
    return commit(store.edit()
      .putString("active:$workspaceId:uri", acquisition.uri)
      .putString("active:$workspaceId:phase", "active")
      .putBoolean("active:$workspaceId:owned", acquisition.owned)
      .putLong("active:$workspaceId:generation", acquisition.generation)
      .putString("active:$workspaceId:rootId", acquisition.rootId)
      .putString("active:$workspaceId:digest", encodeDigest(acquisition.digest))
      .remove("acq:$workspaceId:uri")
      .remove("acq:$workspaceId:phase")
      .remove("acq:$workspaceId:owned")
      .remove("acq:$workspaceId:generation")
      .remove("acq:$workspaceId:rootId")
      .remove("acq:$workspaceId:digest"))
  }

  fun acquisitionIDs(): Set<String> = workspaceIDs("acq:")
  fun activeWorkspaceIDs(): Set<String> = workspaceIDs("active:")
  fun deletingWorkspaceIDs(): Set<String> = workspaceIDs("deleting:")

  /**
   * Writes tombstones for only the old three/two-field prototype schemas.
   * Current versioned records and malformed key groups are never interpreted
   * as legacy authority and therefore can never cause a permission release.
   */
  fun stageLegacyCleanup(): List<AndroidLegacyCleanupRecord>? {
    val existing = legacyCleanupRecords()
    val stagedUris = existing.mapTo(mutableSetOf()) { it.uri }
    val editor = store.edit()
    var changed = false
    legacyGroups().values.groupBy { it.uri }.forEach { (uri, groups) ->
      if (uri !in stagedUris) {
        val key = legacyKey(uri)
        editor.putString("legacy:$key:uri", uri)
        editor.putBoolean("legacy:$key:owned", groups.any { it.owned })
        changed = true
      }
    }
    if (changed && !commit(editor)) return null
    return legacyCleanupRecords()
  }

  /** Removes the tombstone only after its exact legacy groups are retired. */
  fun finishLegacyCleanup(record: AndroidLegacyCleanupRecord): Boolean {
    val editor = store.edit()
    legacyGroups().forEach { (groupKey, group) ->
      if (group.uri == record.uri) {
        groupKey.forEach(editor::remove)
      }
    }
    editor.remove("legacy:${record.key}:uri")
    editor.remove("legacy:${record.key}:owned")
    return commit(editor)
  }

  private fun workspaceIDs(prefix: String): Set<String> = store.all.keys
    .filter { it.startsWith(prefix) }
    .mapNotNull { it.split(':').getOrNull(1) }
    .toSet()

  private fun legacyCleanupRecords(): List<AndroidLegacyCleanupRecord> {
    val groups = store.all.keys.mapNotNull { key ->
      val parts = key.split(':')
      if (parts.size == 3 && parts[0] == "legacy" && parts[2] in setOf("uri", "owned") &&
        parts[1].matches(Regex("[a-f0-9]{64}"))
      ) parts[1] else null
    }.toSet()
    return groups.mapNotNull { key ->
      val uri = store.getString("legacy:$key:uri", null)?.let(::normalizedLegacyUri) ?: return@mapNotNull null
      val owned = store.all["legacy:$key:owned"] as? Boolean ?: return@mapNotNull null
      AndroidLegacyCleanupRecord(key, uri, owned)
    }
  }

  /** Returns exact complete prototype groups keyed by their concrete keys. */
  private fun legacyGroups(): Map<Set<String>, LegacyGroup> {
    val candidates = store.all.keys.mapNotNull { key ->
      val parts = key.split(':')
      if (parts.size == 3 && parts[0] in setOf("acq", "active") && parts[1].isNotEmpty() &&
        parts[1].all { it.isLetterOrDigit() || it == '-' || it == '_' } &&
        parts[2] in setOf("uri", "phase", "owned")
      ) LegacyCandidate(parts[0], parts[1], parts[2], key) else null
    }
    return candidates.groupBy { it.prefix to it.workspaceId }.mapNotNull { (identity, fields) ->
      val prefix = identity.first
      val expected = if (prefix == "acq") setOf("uri", "phase", "owned") else setOf("uri", "owned")
      val workspaceId = fields.first().workspaceId
      val groupFields = store.all.keys.mapNotNull { key ->
        key.removePrefix("$prefix:$workspaceId:").takeIf { key.startsWith("$prefix:$workspaceId:") }
      }.toSet()
      if (groupFields != expected || fields.mapTo(mutableSetOf()) { it.field } != expected) return@mapNotNull null
      val byField = fields.associateBy { it.field }
      val uri = (store.all[requireNotNull(byField["uri"]).key] as? String)?.let(::normalizedLegacyUri)
        ?: return@mapNotNull null
      val owned = store.all[requireNotNull(byField["owned"]).key] as? Boolean ?: return@mapNotNull null
      if (prefix == "acq" && store.all[requireNotNull(byField["phase"]).key] !is String) return@mapNotNull null
      fields.mapTo(mutableSetOf()) { it.key } to LegacyGroup(uri, owned)
    }.toMap()
  }

  private fun normalizedLegacyUri(value: String): String? = try {
    Uri.parse(value).takeIf { it.scheme == "content" }?.normalizeScheme()?.toString()
  } catch (_: Exception) {
    null
  }

  private fun legacyKey(uri: String): String = MessageDigest.getInstance("SHA-256")
    .digest(uri.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }

  private data class LegacyCandidate(val prefix: String, val workspaceId: String, val field: String, val key: String)
  private data class LegacyGroup(val uri: String, val owned: Boolean)

  private fun record(prefix: String): AndroidAcquisitionRecord? {
    val uri = store.getString("$prefix:uri", null) ?: return null
    val phase = store.getString("$prefix:phase", null) ?: return null
    val generation = store.getLong("$prefix:generation", 0).takeIf { it > 0 } ?: return null
    val rootId = store.getString("$prefix:rootId", null)
      ?.takeIf { it.isNotEmpty() && it.all { char -> char.isLetterOrDigit() || char == '-' || char == '_' } }
      ?: return null
    val digest = store.getString("$prefix:digest", null)?.let(::decodeDigest) ?: return null
    if (digest.size != 32) return null
    return AndroidAcquisitionRecord(uri, phase, store.getBoolean("$prefix:owned", false), generation, rootId, digest)
  }

  private fun writeActive(workspaceId: String, record: AndroidAcquisitionRecord): Boolean = commit(
    store.edit()
      .putString("active:$workspaceId:uri", record.uri)
      .putString("active:$workspaceId:phase", record.phase)
      .putBoolean("active:$workspaceId:owned", record.owned)
      .putLong("active:$workspaceId:generation", record.generation)
      .putString("active:$workspaceId:rootId", record.rootId)
      .putString("active:$workspaceId:digest", encodeDigest(record.digest)),
  )

  private fun clear(prefix: String): Boolean = commit(store.edit()
    .remove("$prefix:uri")
    .remove("$prefix:phase")
    .remove("$prefix:owned")
    .remove("$prefix:generation")
    .remove("$prefix:rootId")
    .remove("$prefix:digest"))

  private fun sameAuthority(left: AndroidAcquisitionRecord, right: AndroidAcquisitionRecord): Boolean =
    left.uri == right.uri && left.generation == right.generation && left.rootId == right.rootId &&
      left.digest.contentEquals(right.digest)

  private fun encodeDigest(value: ByteArray): String = java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(value)
  private fun decodeDigest(value: String): ByteArray? = try {
    java.util.Base64.getUrlDecoder().decode(value)
  } catch (_: IllegalArgumentException) {
    null
  }

  private companion object {
    const val STORE_NAME = "workspace_flutter_grants"
  }
}
