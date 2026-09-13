package com.mattsp1290.workspace_flutter.internal

import android.content.Context
import kotlin.jvm.JvmName

/**
 * Optional provider override for controlled host integration. The implementation
 * is absent unless a host installs one before plugin attachment.
 */
internal object WorkspaceDocumentProviderOverride {
  @Volatile private var providerFactory: ((Context) -> AndroidDocumentProvider)? = null

  fun documentProvider(context: Context): AndroidDocumentProvider? = providerFactory?.invoke(context)

  @JvmStatic
  @JvmName("installDocumentProviderFactory")
  internal fun install(factory: (Context) -> AndroidDocumentProvider) {
    providerFactory = factory
  }
}
