package com.mattsp1290.workspace_flutter.internal

import android.content.Intent
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidPickerGrantTest {
  @Test fun `P11 requires both read and persistable picker grants`() {
    assertTrue(AndroidPickerGrant.hasReadAndPersistableAccess(
      Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION,
    ))
    assertFalse(AndroidPickerGrant.hasReadAndPersistableAccess(Intent.FLAG_GRANT_READ_URI_PERMISSION))
    assertFalse(AndroidPickerGrant.hasReadAndPersistableAccess(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION))
  }
}
