package com.mattsp1290.workspace_flutter.internal

import android.content.ContentResolver
import android.net.Uri
import android.os.Build
import android.os.CancellationSignal
import android.provider.DocumentsContract
import androidx.annotation.RequiresApi
import java.io.Closeable
import java.io.FileInputStream
import java.io.InputStream
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * The only production seam that touches document-provider I/O.
 *
 * The operation engine/channel handler supplies all bounds and cancellation;
 * implementations must release framework resources before returning from each
 * method.  Keeping the seam callback based deliberately prevents a provider
 * cursor from escaping into resumable-page state.
 */
interface AndroidDocumentProvider {
  /** Live provider-owned resources; fakes expose the same counters to tests. */
  val resources: AndroidProviderResourceCounters

  fun documentUri(tree: Uri, documentId: String): Uri

  /** Returns false when the framework cannot establish descendant provenance. */
  fun isDescendant(tree: Uri, documentId: String): Boolean

  /**
   * Visits children one at a time. Returning false from [visitor] stops the
   * query; the provider cursor is still closed by the implementation.
   */
  fun forEachChild(
    tree: Uri,
    parentDocumentId: String,
    cancellation: CancellationSignal,
    visitor: (AndroidDocumentChild) -> Boolean,
  )

  fun mimeType(uri: Uri, cancellation: CancellationSignal): String?

  fun openRead(uri: Uri, cancellation: CancellationSignal): AndroidReadHandle?
}

data class AndroidDocumentChild(
  val documentId: String?,
  val displayName: String?,
  val mimeType: String?,
  val byteLength: Long?,
)

interface AndroidReadHandle : Closeable {
  val input: InputStream
  val statSize: Long
  fun seek(position: Long)
}

/** A provider could not serve a request, without exposing provider diagnostics. */
class AndroidProviderUnavailable : RuntimeException()

/** Counters are deliberately separate from operation registration. */
class AndroidProviderResourceCounters {
  private val queryCount = AtomicInteger()
  private val readHandleCount = AtomicInteger()

  val activeQueries: Int get() = queryCount.get()
  val activeReadHandles: Int get() = readHandleCount.get()
  val activeTotal: Int get() = activeQueries + activeReadHandles

  fun openedQuery() = queryCount.incrementAndGet()
  fun closedQuery() = queryCount.decrementAndGet()
  fun openedReadHandle() = readHandleCount.incrementAndGet()
  fun closedReadHandle() = readHandleCount.decrementAndGet()
}

internal class ContentResolverDocumentProvider(
  private val resolver: ContentResolver,
) : AndroidDocumentProvider {
  override val resources = AndroidProviderResourceCounters()
  override fun documentUri(tree: Uri, documentId: String): Uri =
    DocumentsContract.buildDocumentUriUsingTree(tree, documentId)

  override fun isDescendant(tree: Uri, documentId: String): Boolean {
    return AndroidDescendantPolicy.validate(Build.VERSION.SDK_INT) {
      AndroidQDescendantCheck.isDescendant(resolver, tree, documentId)
    }
  }

  override fun forEachChild(
    tree: Uri,
    parentDocumentId: String,
    cancellation: CancellationSignal,
    visitor: (AndroidDocumentChild) -> Boolean,
  ) {
    resources.openedQuery()
    try {
      val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, parentDocumentId)
      resolver.query(
        children,
        arrayOf(
          DocumentsContract.Document.COLUMN_DOCUMENT_ID,
          DocumentsContract.Document.COLUMN_DISPLAY_NAME,
          DocumentsContract.Document.COLUMN_MIME_TYPE,
          DocumentsContract.Document.COLUMN_SIZE,
        ),
        null,
        null,
        null,
        cancellation,
      )?.use { cursor ->
        while (cursor.moveToNext()) {
          val size = if (cursor.isNull(3)) null else cursor.getLong(3)
          if (!visitor(AndroidDocumentChild(cursor.getString(0), cursor.getString(1), cursor.getString(2), size))) {
            return
          }
        }
      } ?: throw AndroidProviderUnavailable()
    } finally {
      resources.closedQuery()
    }
  }

  override fun mimeType(uri: Uri, cancellation: CancellationSignal): String? =
    run {
      resources.openedQuery()
      try {
        resolver.query(
          uri,
          arrayOf(DocumentsContract.Document.COLUMN_MIME_TYPE),
          null,
          null,
          null,
          cancellation,
        )?.use { cursor ->
          if (!cursor.moveToFirst()) null else cursor.getString(0)
        } ?: throw AndroidProviderUnavailable()
      } finally {
        resources.closedQuery()
      }
    }

  override fun openRead(uri: Uri, cancellation: CancellationSignal): AndroidReadHandle? {
    val descriptor = resolver.openFileDescriptor(uri, "r", cancellation) ?: return null
    resources.openedReadHandle()
    return ParcelReadHandle(descriptor, resources)
  }

  private class ParcelReadHandle(
    private val descriptor: android.os.ParcelFileDescriptor,
    private val resources: AndroidProviderResourceCounters,
  ) : AndroidReadHandle {
    private val closed = AtomicBoolean(false)
    override val input: InputStream = FileInputStream(descriptor.fileDescriptor)
    override val statSize: Long get() = descriptor.statSize

    override fun seek(position: Long) {
      (input as FileInputStream).channel.position(position)
    }

    override fun close() {
      if (!closed.compareAndSet(false, true)) return
      try {
        input.close()
      } finally {
        try {
          descriptor.close()
        } finally {
          resources.closedReadHandle()
        }
      }
    }
  }
}

/** Keeps the API gate independently testable without loading Q-only symbols. */
internal object AndroidDescendantPolicy {
  fun validate(apiLevel: Int, qOrLaterProbe: () -> Boolean): Boolean =
    if (apiLevel < Build.VERSION_CODES.Q) true else qOrLaterProbe()
}

/** Isolates the API-29 framework symbol so pre-Q calls never load it. */
@RequiresApi(Build.VERSION_CODES.Q)
private object AndroidQDescendantCheck {
  fun isDescendant(resolver: ContentResolver, tree: Uri, documentId: String): Boolean {
    val rootId = DocumentsContract.getTreeDocumentId(tree)
    if (documentId == rootId) return true
    val root = DocumentsContract.buildDocumentUriUsingTree(tree, rootId)
    val candidate = DocumentsContract.buildDocumentUriUsingTree(tree, documentId)
    return DocumentsContract.isChildDocument(resolver, root, candidate)
  }
}
