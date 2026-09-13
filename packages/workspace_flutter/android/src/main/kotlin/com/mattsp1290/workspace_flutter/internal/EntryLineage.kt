package com.mattsp1290.workspace_flutter.internal

import java.util.Base64

/** App-private record for one public opaque entry ID. */
internal data class EntryRecord(
  val parentId: String?,
  val documentId: String,
)

/** Codec and bounded chain verification for root-confined entry records. */
internal object EntryLineage {
  const val maxDepth = 256

  fun encode(record: EntryRecord): String {
    val parent = record.parentId ?: ""
    val document = Base64.getUrlEncoder().withoutPadding()
      .encodeToString(record.documentId.toByteArray(Charsets.UTF_8))
    return "$parent.$document"
  }

  fun decode(value: String): EntryRecord? {
    val separator = value.indexOf('.')
    if (separator < 0) return null
    val parent = value.substring(0, separator).ifEmpty { null }
    if (parent != null && !isOpaqueId(parent)) return null
    return try {
      val document = String(Base64.getUrlDecoder().decode(value.substring(separator + 1)), Charsets.UTF_8)
      if (document.isEmpty()) null else EntryRecord(parent, document)
    } catch (_: IllegalArgumentException) {
      null
    }
  }

  /** Returns the requested record only when its private chain ends at [rootDocumentId]. */
  fun resolve(
    stableId: String,
    rootDocumentId: String,
    lookup: (String) -> EntryRecord?,
  ): EntryRecord? {
    if (!isOpaqueId(stableId)) return null
    val requested = lookup(stableId) ?: return null
    var currentId: String? = stableId
    var current = requested
    val seen = mutableSetOf<String>()
    repeat(maxDepth) {
      val id = currentId ?: return@repeat
      if (!seen.add(id)) return null
      val parentId = current.parentId
      if (parentId == null) return if (current.documentId == rootDocumentId) requested else null
      currentId = parentId
      current = lookup(parentId) ?: return null
    }
    return null
  }

  private fun isOpaqueId(value: String): Boolean =
    value.matches(Regex("^[A-Za-z0-9_-]{1,512}$"))
}
