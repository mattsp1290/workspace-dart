package com.mattsp1290.workspace_flutter

import android.database.Cursor
import android.database.MatrixCursor
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract.Document
import android.provider.DocumentsContract.Root
import android.provider.DocumentsProvider
import java.io.File

/** A deterministic provider used only by the instrumentation APK. */
class WorkspaceTestDocumentProvider : DocumentsProvider() {
  override fun onCreate(): Boolean = true

  override fun isChildDocument(parentDocumentId: String, documentId: String): Boolean =
    parentDocumentId == ROOT_ID && documentId in setOf(ROOT_ID, FILE_ID)

  override fun queryRoots(projection: Array<out String>?): Cursor {
    return MatrixCursor(projection ?: ROOT_COLUMNS).apply {
      newRow()
        .add(Root.COLUMN_ROOT_ID, ROOT_ID)
        .add(Root.COLUMN_DOCUMENT_ID, ROOT_ID)
        .add(Root.COLUMN_TITLE, "Workspace test root")
        .add(Root.COLUMN_FLAGS, Root.FLAG_SUPPORTS_CREATE)
    }
  }

  override fun queryDocument(documentId: String, projection: Array<out String>?): Cursor {
    require(documentId == ROOT_ID || documentId == FILE_ID)
    return MatrixCursor(projection ?: DOCUMENT_COLUMNS).apply {
      newRow()
        .add(Document.COLUMN_DOCUMENT_ID, documentId)
        .add(Document.COLUMN_DISPLAY_NAME, if (documentId == ROOT_ID) "root" else "fixture.txt")
        .add(Document.COLUMN_MIME_TYPE, if (documentId == ROOT_ID) Document.MIME_TYPE_DIR else "text/plain")
        .add(Document.COLUMN_FLAGS, 0)
        .add(Document.COLUMN_SIZE, if (documentId == ROOT_ID) 0L else CONTENT.size.toLong())
    }
  }

  override fun queryChildDocuments(
    parentDocumentId: String,
    projection: Array<out String>?,
    sortOrder: String?,
  ): Cursor {
    require(parentDocumentId == ROOT_ID)
    return queryDocument(FILE_ID, projection)
  }

  override fun openDocument(documentId: String, mode: String, signal: android.os.CancellationSignal?): ParcelFileDescriptor {
    require(documentId == FILE_ID)
    require(mode == "r")
    val file = File(requireNotNull(context).cacheDir, "workspace-test-document.txt")
    file.writeBytes(CONTENT)
    return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
  }

  companion object {
    const val AUTHORITY = "com.mattsp1290.workspace_flutter.testdocuments"
    const val ROOT_ID = "root"
    const val FILE_ID = "fixture.txt"
    val CONTENT = "controlled provider content".encodeToByteArray()

    private val ROOT_COLUMNS = arrayOf(
      Root.COLUMN_ROOT_ID,
      Root.COLUMN_DOCUMENT_ID,
      Root.COLUMN_TITLE,
      Root.COLUMN_FLAGS,
    )
    private val DOCUMENT_COLUMNS = arrayOf(
      Document.COLUMN_DOCUMENT_ID,
      Document.COLUMN_DISPLAY_NAME,
      Document.COLUMN_MIME_TYPE,
      Document.COLUMN_FLAGS,
      Document.COLUMN_SIZE,
    )
  }
}
