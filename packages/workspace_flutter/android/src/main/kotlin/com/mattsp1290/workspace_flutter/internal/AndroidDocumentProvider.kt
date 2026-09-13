package com.mattsp1290.workspace_flutter.internal

import android.content.ContentResolver
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.os.CancellationSignal
import android.provider.DocumentsContract
import androidx.annotation.RequiresApi
import java.io.Closeable
import java.io.FileInputStream
import java.io.InputStream
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.ConcurrentHashMap

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

/** Small framework boundary so JVM tests can inject null/failing provider I/O. */
internal interface AndroidResolver {
  fun query(uri: Uri, projection: Array<String>, cancellation: CancellationSignal): Cursor?
  fun openRead(uri: Uri, cancellation: CancellationSignal): android.os.ParcelFileDescriptor?
  fun isChildDocument(parent: Uri, candidate: Uri): Boolean
}

private class FrameworkAndroidResolver(
  private val resolver: ContentResolver,
) : AndroidResolver {
  override fun query(
    uri: Uri,
    projection: Array<String>,
    cancellation: CancellationSignal,
  ): Cursor? = resolver.query(uri, projection, null, null, null, cancellation)

  override fun openRead(
    uri: Uri,
    cancellation: CancellationSignal,
  ): android.os.ParcelFileDescriptor? = resolver.openFileDescriptor(uri, "r", cancellation)

  override fun isChildDocument(parent: Uri, candidate: Uri): Boolean =
    DocumentsContract.isChildDocument(resolver, parent, candidate)
}

/** A provider could not serve a request, without exposing provider diagnostics. */
class AndroidProviderUnavailable : RuntimeException()

/** Counters are deliberately separate from operation registration. */
class AndroidProviderResourceCounters {
  private val activeQueryLeases = ConcurrentHashMap.newKeySet<AndroidProviderResourceLease>()
  private val activeReadLeases = ConcurrentHashMap.newKeySet<AndroidProviderResourceLease>()

  val activeQueries: Int get() = activeQueryLeases.size
  val activeReadHandles: Int get() = activeReadLeases.size
  val activeTotal: Int get() = activeQueries + activeReadHandles

  fun acquireQuery(): AndroidProviderResourceLease = acquire(activeQueryLeases)
  fun acquireReadHandle(): AndroidProviderResourceLease = acquire(activeReadLeases)

  private fun acquire(
    active: MutableSet<AndroidProviderResourceLease>,
  ): AndroidProviderResourceLease {
    lateinit var lease: AndroidProviderResourceLease
    lease = AndroidProviderResourceLease {
      check(active.remove(lease)) { "provider resource lease was released without ownership" }
    }
    check(active.add(lease)) { "provider resource lease was acquired twice" }
    return lease
  }
}

/** Exact ownership token for one framework query or read descriptor. */
class AndroidProviderResourceLease internal constructor(
  private val release: () -> Unit,
) : Closeable {
  private val closed = AtomicBoolean(false)

  override fun close() {
    check(closed.compareAndSet(false, true)) { "provider resource lease closed twice" }
    release()
  }
}

internal class ContentResolverDocumentProvider(
  private val resolver: AndroidResolver,
) : AndroidDocumentProvider {
  constructor(resolver: ContentResolver) : this(FrameworkAndroidResolver(resolver))
  override val resources = AndroidProviderResourceCounters()
  override fun documentUri(tree: Uri, documentId: String): Uri =
    DocumentsContract.buildDocumentUriUsingTree(tree, documentId)

  override fun isDescendant(tree: Uri, documentId: String): Boolean {
    return try {
      AndroidDescendantPolicy.validate(Build.VERSION.SDK_INT) {
        AndroidQDescendantCheck.isDescendant(resolver, tree, documentId)
      }
    } catch (_: SecurityException) {
      // Providers may reject a forged candidate before answering the
      // descendant query. That is failed proof, never alternate authority.
      false
    } catch (_: IllegalArgumentException) {
      false
    }
  }

  override fun forEachChild(
    tree: Uri,
    parentDocumentId: String,
    cancellation: CancellationSignal,
    visitor: (AndroidDocumentChild) -> Boolean,
  ) {
    val lease = resources.acquireQuery()
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
      lease.close()
    }
  }

  override fun mimeType(uri: Uri, cancellation: CancellationSignal): String? =
    run {
      val lease = resources.acquireQuery()
      try {
        resolver.query(
          uri,
          arrayOf(DocumentsContract.Document.COLUMN_MIME_TYPE),
          cancellation,
        )?.use { cursor ->
          if (!cursor.moveToFirst()) null else cursor.getString(0)
        } ?: throw AndroidProviderUnavailable()
      } finally {
        lease.close()
      }
    }

  override fun openRead(uri: Uri, cancellation: CancellationSignal): AndroidReadHandle? {
    val lease = resources.acquireReadHandle()
    var transferred = false
    try {
      val descriptor = resolver.openRead(uri, cancellation) ?: return null
      return ParcelReadHandle(descriptor, lease).also { transferred = true }
    } finally {
      // Ownership transfers to ParcelReadHandle only on a successful return.
      // A failed/null descriptor must not leave an unmatched lease.
      if (!transferred) lease.close()
    }
  }

  private class ParcelReadHandle(
    private val descriptor: android.os.ParcelFileDescriptor,
    private val lease: AndroidProviderResourceLease,
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
          lease.close()
        }
      }
    }
  }
}

/** Keeps the API gate independently testable without loading Q-only symbols. */
internal object AndroidDescendantPolicy {
  fun validate(apiLevel: Int, qOrLaterProbe: () -> Boolean): Boolean =
    apiLevel >= Build.VERSION_CODES.Q && qOrLaterProbe()
}

/** Isolates the API-29 framework symbol so pre-Q calls never load it. */
@RequiresApi(Build.VERSION_CODES.Q)
private object AndroidQDescendantCheck {
  fun isDescendant(resolver: AndroidResolver, tree: Uri, documentId: String): Boolean {
    val rootId = DocumentsContract.getTreeDocumentId(tree)
    if (documentId == rootId) return true
    val root = DocumentsContract.buildDocumentUriUsingTree(tree, rootId)
    val candidate = DocumentsContract.buildDocumentUriUsingTree(tree, documentId)
    return resolver.isChildDocument(root, candidate)
  }
}
