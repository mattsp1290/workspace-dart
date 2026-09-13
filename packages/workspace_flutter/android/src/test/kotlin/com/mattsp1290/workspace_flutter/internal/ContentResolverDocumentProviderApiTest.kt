package com.mattsp1290.workspace_flutter.internal

import android.os.Build
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.net.Uri
import android.provider.DocumentsContract
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
class ContentResolverDocumentProviderApiTest {
  @Test
  fun nullQueryFailsAsUnavailableAndReleasesItsExactLease() {
    val provider = ContentResolverDocumentProvider(nullResolver())
    val tree = DocumentsContract.buildTreeDocumentUri("test.provider", "root")

    try {
      provider.forEachChild(tree, "root", CancellationSignal()) { true }
      throw AssertionError("expected unavailable provider result")
    } catch (_: AndroidProviderUnavailable) {
      // Null cursors are never reinterpreted as an empty directory.
    }

    assertEquals(0, provider.resources.activeTotal)
  }

  @Test
  fun nullDescriptorReleasesItsExactReadLease() {
    val provider = ContentResolverDocumentProvider(nullResolver())

    assertEquals(null, provider.openRead(Uri.parse("content://test.provider/document/file"), CancellationSignal()))
    assertEquals(0, provider.resources.activeTotal)
  }

  @Test
  @Config(sdk = [24, 28])
  fun preQFailsClosedWithoutExecutingTheFrameworkDescendantProbe() {
    var invoked = false

    val descendant = AndroidDescendantPolicy.validate(Build.VERSION.SDK_INT) {
      invoked = true
      false
    }

    assertFalse(descendant)
    assertFalse(invoked)
  }

  @Test
  @Config(sdk = [29, 35])
  fun qAndLaterExecuteAndPropagateTheFrameworkDescendantProbe() {
    var invoked = false

    val descendant = AndroidDescendantPolicy.validate(Build.VERSION.SDK_INT) {
      invoked = true
      false
    }

    assertFalse(descendant)
    assertTrue(invoked)
    assertEquals(true, Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
  }

  private fun nullResolver(): AndroidResolver = object : AndroidResolver {
    override fun query(
      uri: Uri,
      projection: Array<String>,
      cancellation: CancellationSignal,
    ) = null

    override fun openRead(uri: Uri, cancellation: CancellationSignal): ParcelFileDescriptor? = null

    override fun isChildDocument(parent: Uri, candidate: Uri): Boolean = false
  }
}
