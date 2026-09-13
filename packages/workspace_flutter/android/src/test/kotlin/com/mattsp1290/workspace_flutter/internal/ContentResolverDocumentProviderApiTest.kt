package com.mattsp1290.workspace_flutter.internal

import android.os.Build
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
  @Config(sdk = [24, 28])
  fun preQDoesNotExecuteTheFrameworkDescendantProbe() {
    var invoked = false

    val descendant = AndroidDescendantPolicy.validate(Build.VERSION.SDK_INT) {
      invoked = true
      false
    }

    assertTrue(descendant)
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
}
