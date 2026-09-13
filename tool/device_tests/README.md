# Physical device probe

Use only synthetic content. The example app persists opaque grants in its
app-private test vault and displays safe outcome summaries.

## Android

1. Create `Documents/workspace_dart_probe` on the test device and copy
   `fixtures/sample.txt` into it.
2. Run the example on the AYN Thor.
3. Select that directory with the system picker.
4. Force-stop the app, relaunch it, and tap **Restore, list, and read**.
5. Record only the device/OS/provider tuple and typed outcome. Never record the
   tree URI, native document IDs, or file contents.

## iOS

Create the same synthetic folder in Files, select it in the example app,
terminate the app externally, relaunch it, and run the restore/read action.
The host must allow the terminal local-network access when the iPhone is
connected wirelessly.
