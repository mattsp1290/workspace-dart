package com.mattsp1290.workspace_flutter_example

import android.net.Uri
import android.os.CancellationSignal
import android.provider.DocumentsContract
import com.mattsp1290.workspace_flutter.internal.AndroidDocumentChild
import com.mattsp1290.workspace_flutter.internal.AndroidDocumentProvider
import com.mattsp1290.workspace_flutter.internal.AndroidProviderResourceCounters
import com.mattsp1290.workspace_flutter.internal.AndroidReadHandle
import com.mattsp1290.workspace_flutter.internal.AndroidProviderUnavailable
import java.io.ByteArrayInputStream
import java.io.FileNotFoundException
import java.io.IOException
import java.io.InputStream

/** Controlled provider seam used by nativeTest integration calls only. */
class WorkspaceFixtureDocumentProvider : AndroidDocumentProvider {
    override val resources = AndroidProviderResourceCounters()

    override fun documentUri(tree: Uri, documentId: String): Uri = tree.buildUpon()
        .appendPath(documentId)
        .build()

    override fun isDescendant(tree: Uri, documentId: String): Boolean =
        documentId in setOf(
            rootId,
            fileId,
            deniedRootId,
            missingRootId,
            blockedRootId,
            unavailableRootId,
            providerFailureRootId,
            deadlineRootId,
            blockedReadRootId,
            blockedReadFileId,
        )

    override fun forEachChild(
        tree: Uri,
        parentDocumentId: String,
        cancellation: CancellationSignal,
        visitor: (AndroidDocumentChild) -> Boolean,
    ) {
        if (parentDocumentId == deniedRootId) throw SecurityException("fixture access denied")
        if (parentDocumentId == missingRootId) throw FileNotFoundException("fixture root missing")
        if (parentDocumentId == blockedRootId) {
            while (!cancellation.isCanceled) Thread.sleep(5)
            throw java.util.concurrent.CancellationException("fixture cancelled")
        }
        if (parentDocumentId == unavailableRootId) throw AndroidProviderUnavailable()
        if (parentDocumentId == providerFailureRootId) {
            visitor(AndroidDocumentChild(fileId, null, "text/plain", contents.size.toLong()))
            return
        }
        if (parentDocumentId == deadlineRootId) {
            Thread.sleep(20)
            visitor(AndroidDocumentChild(fileId, "deadline.txt", "text/plain", contents.size.toLong()))
            return
        }
        if (parentDocumentId == blockedReadRootId) {
            visitor(AndroidDocumentChild(blockedReadFileId, "blocked.txt", "text/plain", contents.size.toLong()))
            return
        }
        require(parentDocumentId == rootId)
        resources.openedQuery()
        try {
            if (!visitor(AndroidDocumentChild(fileId, "fixture.txt", "text/plain", contents.size.toLong()))) {
                return
            }
            visitor(AndroidDocumentChild(nextFileId, "next.txt", "text/plain", nextContents.size.toLong()))
        } finally {
            resources.closedQuery()
        }
    }

    override fun mimeType(uri: Uri, cancellation: CancellationSignal): String? = when {
        uri.pathSegments.lastOrNull() == rootId -> DocumentsContract.Document.MIME_TYPE_DIR
        uri.pathSegments.lastOrNull() == blockedReadRootId -> DocumentsContract.Document.MIME_TYPE_DIR
        uri.toString().endsWith(fileId) -> "text/plain"
        else -> null
    }

    override fun openRead(uri: Uri, cancellation: CancellationSignal): AndroidReadHandle? {
        if (uri.pathSegments.lastOrNull() == blockedReadFileId) {
            while (!cancellation.isCanceled) Thread.sleep(5)
            throw java.util.concurrent.CancellationException("fixture read cancelled")
        }
        if (!uri.toString().endsWith(fileId)) return null
        return FixtureReadHandle(contents, resources)
    }

    private class FixtureReadHandle(
        private val bytes: ByteArray,
        private val counters: AndroidProviderResourceCounters,
    ) : AndroidReadHandle {
        private var stream = ByteArrayInputStream(bytes)
        private var closed = false

        init {
            counters.openedReadHandle()
        }

        override val input: InputStream get() = stream
        override val statSize: Long get() = bytes.size.toLong()

        override fun seek(position: Long) {
            if (position !in 0..bytes.size.toLong()) throw IOException("fixture seek past EOF")
            stream.reset()
            stream.skip(position)
        }

        override fun close() {
            if (closed) return
            closed = true
            stream.close()
            counters.closedReadHandle()
        }
    }

    private companion object {
        const val rootId = "root"
        const val fileId = "fixture.txt"
        const val nextFileId = "next.txt"
        const val deniedRootId = "denied"
        const val missingRootId = "missing"
        const val blockedRootId = "blocked"
        const val unavailableRootId = "unavailable"
        const val providerFailureRootId = "provider-failure"
        const val deadlineRootId = "deadline"
        const val blockedReadRootId = "blocked-read"
        const val blockedReadFileId = "blocked.txt"
        val contents = "native test fixture".encodeToByteArray()
        val nextContents = "native test cursor fixture".encodeToByteArray()
    }
}
