package com.mattsp1290.workspace_flutter_example

import android.database.Cursor
import android.database.MatrixCursor
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract.Document
import android.provider.DocumentsContract.Root
import android.provider.DocumentsProvider
import java.io.File

/**
 * Synthetic SAF provider compiled only into the `nativeTest` flavor. It is
 * deliberately not reachable from the ordinary production artifact.
 */
class WorkspaceTestDocumentProvider : DocumentsProvider() {
    override fun onCreate(): Boolean = true

    override fun queryRoots(projection: Array<out String>?): Cursor =
        MatrixCursor(projection ?: rootColumns).apply {
            newRow()
                .add(Root.COLUMN_ROOT_ID, rootId)
                .add(Root.COLUMN_DOCUMENT_ID, rootId)
                .add(Root.COLUMN_TITLE, "Native test workspace")
                .add(Root.COLUMN_FLAGS, 0)
        }

    override fun queryDocument(documentId: String, projection: Array<out String>?): Cursor {
        require(documentId == rootId || documentId == fileId)
        return MatrixCursor(projection ?: documentColumns).apply {
            newRow()
                .add(Document.COLUMN_DOCUMENT_ID, documentId)
                .add(Document.COLUMN_DISPLAY_NAME, if (documentId == rootId) "root" else "fixture.txt")
                .add(Document.COLUMN_MIME_TYPE, if (documentId == rootId) Document.MIME_TYPE_DIR else "text/plain")
                .add(Document.COLUMN_FLAGS, 0)
                .add(Document.COLUMN_SIZE, if (documentId == rootId) 0L else contents.size.toLong())
        }
    }

    override fun queryChildDocuments(
        parentDocumentId: String,
        projection: Array<out String>?,
        sortOrder: String?,
    ): Cursor {
        require(parentDocumentId == rootId)
        return queryDocument(fileId, projection)
    }

    override fun openDocument(
        documentId: String,
        mode: String,
        signal: android.os.CancellationSignal?,
    ): ParcelFileDescriptor {
        require(documentId == fileId)
        require(mode == "r")
        val file = File(requireNotNull(context).cacheDir, "native-test-fixture.txt")
        file.writeBytes(contents)
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    private companion object {
        const val rootId = "root"
        const val fileId = "fixture.txt"
        val contents = "native test fixture".encodeToByteArray()
        val rootColumns = arrayOf(
            Root.COLUMN_ROOT_ID,
            Root.COLUMN_DOCUMENT_ID,
            Root.COLUMN_TITLE,
            Root.COLUMN_FLAGS,
        )
        val documentColumns = arrayOf(
            Document.COLUMN_DOCUMENT_ID,
            Document.COLUMN_DISPLAY_NAME,
            Document.COLUMN_MIME_TYPE,
            Document.COLUMN_FLAGS,
            Document.COLUMN_SIZE,
        )
    }
}
