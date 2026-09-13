package com.mattsp1290.workspace_flutter.internal

import android.content.Intent

/** Exact authority required before a selected tree can enter the grant journal. */
internal object AndroidPickerGrant {
  fun hasReadAndPersistableAccess(flags: Int): Boolean {
    val required = Intent.FLAG_GRANT_READ_URI_PERMISSION or
      Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
    return flags and required == required
  }
}
