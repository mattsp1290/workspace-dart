package com.mattsp1290.workspace_flutter

import android.provider.DocumentsContract
import com.mattsp1290.workspace_flutter.internal.ContentResolverDocumentProvider
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class WorkspaceTestDocumentProviderTest {
  @Test
  fun childrenAreAvailableThroughTheFrameworkContentResolver() {
    val resolver = ApplicationProvider.getApplicationContext<android.content.Context>().contentResolver
    val children = DocumentsContract.buildChildDocumentsUri(
      WorkspaceTestDocumentProvider.AUTHORITY,
      WorkspaceTestDocumentProvider.ROOT_ID,
    )

    resolver.query(children, null, null, null, null).use { cursor ->
      assertNotNull(cursor)
      requireNotNull(cursor)
      assertEquals(1, cursor.count)
      cursor.moveToFirst()
      assertEquals(
        WorkspaceTestDocumentProvider.FILE_ID,
        cursor.getString(cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DOCUMENT_ID)),
      )
    }
  }

  @Test
  fun productionProviderSeamReadsTheControlledDocumentAndReleasesResources() {
    val resolver = ApplicationProvider.getApplicationContext<android.content.Context>().contentResolver
    val provider = ContentResolverDocumentProvider(resolver)
    val tree = DocumentsContract.buildTreeDocumentUri(
      WorkspaceTestDocumentProvider.AUTHORITY,
      WorkspaceTestDocumentProvider.ROOT_ID,
    )
    val children = mutableListOf<String>()

    provider.forEachChild(tree, WorkspaceTestDocumentProvider.ROOT_ID, android.os.CancellationSignal()) {
      children += requireNotNull(it.documentId)
      true
    }

    assertEquals(listOf(WorkspaceTestDocumentProvider.FILE_ID), children)
    assertEquals(0, provider.resources.activeTotal)

    val document = provider.documentUri(tree, WorkspaceTestDocumentProvider.FILE_ID)
    val handle = requireNotNull(provider.openRead(document, android.os.CancellationSignal()))
    handle.use {
      assertEquals(
        WorkspaceTestDocumentProvider.CONTENT.decodeToString(),
        it.input.readBytes().decodeToString(),
      )
    }
    assertEquals(0, provider.resources.activeTotal)
  }
}
