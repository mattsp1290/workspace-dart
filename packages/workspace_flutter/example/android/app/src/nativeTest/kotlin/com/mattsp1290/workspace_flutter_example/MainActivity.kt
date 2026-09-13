package com.mattsp1290.workspace_flutter_example

import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        WorkspaceTestBootstrap.install()
        super.onCreate(savedInstanceState)
    }
}
