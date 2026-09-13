package com.mattsp1290.workspace_flutter.internal

import android.content.Context
import java.util.Base64

internal data class AndroidRootRecord(
  val documentId: String,
  val generation: Long,
  val rootId: String,
  val digest: ByteArray,
)

/** Private root binding and opaque entry-lineage persistence. */
internal class AndroidEntryStore(context: Context) {
  private val store = context.getSharedPreferences(STORE_NAME, Context.MODE_PRIVATE)

  fun clearWorkspace(workspaceId: String): Boolean {
    val editor = store.edit()
    store.all.keys.filter { it.startsWith("$workspaceId:") }.forEach(editor::remove)
    editor.remove(rootKey(workspaceId))
    return editor.commit()
  }

  fun rootDocumentId(workspaceId: String): String? = rootRecord(workspaceId)?.documentId

  fun rootRecord(workspaceId: String): AndroidRootRecord? =
    store.getString(rootKey(workspaceId), null)?.let(::decodeRoot)

  fun hasRootState(workspaceId: String): Boolean = store.contains(rootKey(workspaceId))

  fun bindRoot(workspaceId: String, record: AndroidRootRecord): Boolean {
    val key = rootKey(workspaceId)
    val existing = rootRecord(workspaceId)
    return if (existing == null) {
      !hasRootState(workspaceId) && store.edit().putString(key, encodeRoot(record)).commit()
    } else {
      existing.documentId == record.documentId && existing.generation == record.generation &&
        existing.rootId == record.rootId && existing.digest.contentEquals(record.digest)
    }
  }

  /** Returns null when any private record for this workspace is malformed. */
  fun records(workspaceId: String): Map<String, EntryRecord>? {
    val prefix = "$workspaceId:"
    val records = linkedMapOf<String, EntryRecord>()
    for ((key, value) in store.all) {
      if (!key.startsWith(prefix)) continue
      val encoded = value as? String ?: return null
      val record = EntryLineage.decode(encoded) ?: return null
      records[key.removePrefix(prefix)] = record
    }
    return records
  }

  fun putRecords(workspaceId: String, records: Map<String, EntryRecord>): Boolean {
    val editor = store.edit()
    records.forEach { (entryId, record) ->
      editor.putString("$workspaceId:$entryId", EntryLineage.encode(record))
    }
    return editor.commit()
  }

  fun record(workspaceId: String, entryId: String): EntryRecord? =
    store.getString("$workspaceId:$entryId", null)?.let(EntryLineage::decode)

  fun workspaceIDs(): Set<String> = store.all.keys.mapNotNull { key ->
    when {
      key.startsWith("root-binding:") -> key.removePrefix("root-binding:")
      ':' in key -> key.substringBefore(':')
      else -> null
    }
  }.toSet()

  private fun rootKey(workspaceId: String): String = "root-binding:$workspaceId"

  private fun encodeRoot(record: AndroidRootRecord): String {
    val encoder = Base64.getUrlEncoder().withoutPadding()
    return listOf(
      "1",
      record.generation.toString(),
      record.rootId,
      encoder.encodeToString(record.digest),
      encoder.encodeToString(record.documentId.toByteArray(Charsets.UTF_8)),
    ).joinToString(".")
  }

  private fun decodeRoot(encoded: String): AndroidRootRecord? {
    val parts = encoded.split('.')
    if (parts.size != 5 || parts[0] != "1") return null
    val generation = parts[1].toLongOrNull()?.takeIf { it > 0 } ?: return null
    if (parts[2].isEmpty() || parts[2].length > 512 || !parts[2].all { it.isLetterOrDigit() || it == '-' || it == '_' }) return null
    return try {
      val decoder = Base64.getUrlDecoder()
      val digest = decoder.decode(parts[3])
      val documentId = String(decoder.decode(parts[4]), Charsets.UTF_8)
      if (digest.size != 32 || documentId.isEmpty()) null
      else AndroidRootRecord(documentId, generation, parts[2], digest)
    } catch (_: IllegalArgumentException) {
      null
    }
  }

  private companion object {
    const val STORE_NAME = "workspace_flutter_entries"
  }
}
