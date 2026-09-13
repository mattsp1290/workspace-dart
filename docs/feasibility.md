# Native feasibility evidence

Evidence date: 2026-09-13. Source state: committed local hardening based on
`38fc3b8`; no published immutable release pin is claimed yet.

## Toolchain

- Flutter 3.47.1 stable and Dart 3.13.1.
- Xcode 26.2. The plugin deployment target is iOS 18.2.
- Android SDK 36.1.0 with Android Studio JDK 21 and plugin JVM bytecode target
  11. The plugin minimum Android API is 29. API 24--28 are deliberately
  unsupported because they cannot provide the framework descendant proof used
  to contain stored document lineage.

## Automated evidence

- The pure-Dart analyzer and 12 memory-adapter tests pass.
- The Flutter analyzer and 16 bridge/grant-manager tests pass.
- The example analyzer passes.
- `flutter build apk --debug --flavor production` passes; the separate
  `nativeTest` flavor contains controlled-provider fixtures only, and the
  production APK has no fixture markers.
- `flutter build ios --no-codesign` passes.
- On an API 36.1 emulator, the Android `nativeTest` flavor passed 28
  registered-plugin conformance cases and the plugin instrumentation target
  passed five controlled `DocumentsProvider` framework tests. The same five
  instrumentation tests and 28 registered cases also pass on the AYN Thor.
- The iOS 18.2 simulator passed eight registered production-handler cases,
  27 controlled native-fixture cases, and 11 linked-plugin XCTest cases; its
  dedicated compatibility host builds, installs, and launches.
- Both production artifacts pass the fixture-marker exclusion scans.

## Incomplete physical evidence

- The Android system-picker journey could not complete because another
  foreground test application on the shared device repeatedly displaced the
  document picker. No selection, restart restoration, provider traversal, or
  resource-balance claim is made from that attempt.
- Cloud-only, provider failure, revocation, moved/deleted entry, concurrent
  mutation, hard-kill acquisition-window, and every required iPhone local or
  cloud-provider row remain unverified.

Never add tree URIs, bookmark data, native document IDs, absolute user paths,
or file contents to this document.
