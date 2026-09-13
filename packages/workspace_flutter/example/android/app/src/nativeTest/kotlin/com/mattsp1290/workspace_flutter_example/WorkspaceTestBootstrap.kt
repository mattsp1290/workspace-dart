package com.mattsp1290.workspace_flutter_example

import android.content.Context
import com.mattsp1290.workspace_flutter.internal.AndroidDocumentProvider
import kotlin.jvm.functions.Function1

/** Installs the flavor-only provider before Flutter creates plugin instances. */
object WorkspaceTestBootstrap {
    @JvmStatic
    fun install() {
        val hooks = Class.forName(
            "com.mattsp1290.workspace_flutter.internal.WorkspaceDocumentProviderOverride",
        )
        val factory = object : Function1<Context, AndroidDocumentProvider> {
            override fun invoke(context: Context): AndroidDocumentProvider = WorkspaceFixtureDocumentProvider()
        }
        hooks.getMethod("installDocumentProviderFactory", Function1::class.java).invoke(null, factory)
    }
}
