# Native feasibility evidence

Evidence date: 2026-09-13. Source state: uncommitted implementation based on
`16bbd2f`; do not cite an immutable release pin yet.

## Toolchain

- Flutter 3.47.1 stable and Dart 3.13.1.
- Xcode 26.2. The plugin deployment target is iOS 18.2.
- Android SDK 36.1.0 with Android Studio JDK 21 and plugin JVM bytecode target
  11. The plugin minimum Android API is 24.

## Automated evidence

- The pure-Dart analyzer and 11 memory-adapter tests pass.
- The Flutter analyzer and 7 bridge/grant-manager tests pass.
- The example analyzer and app-private vault test pass.
- `flutter build apk --debug --flavor production` passes; the separate
  `nativeTest` flavor contains controlled-provider fixtures only, and the
  production APK has no fixture markers.
- `flutter build ios --no-codesign` passes.
- On an API 36.1 emulator, the Android `nativeTest` flavor passed nine
  registered-plugin conformance cases and the plugin instrumentation target
  passed its controlled `DocumentsProvider` framework tests.
- The iOS 18.2 simulator passed registered protocol and controlled fixture
  cases; its dedicated compatibility host builds, installs, and launches.
- The registered Kotlin plugin passes the invalid-grant and reconciliation
  smoke test on the AYN Thor running Android 13.

## Incomplete physical evidence

- The Android system-picker journey could not complete because another
  foreground test application on the shared device repeatedly displaced the
  document picker. No selection, restart restoration, provider traversal, or
  resource-balance claim is made from that attempt.
- Cloud-only, provider failure, revocation, moved/deleted entry, concurrent
  mutation, and hard-kill acquisition-window rows remain unverified.

Never add tree URIs, bookmark data, native document IDs, absolute user paths,
or file contents to this document.
