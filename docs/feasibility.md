# Native feasibility evidence

Evidence date: 2026-09-13. Source state: published commit
`d3de2811958768cef428307c3bb0d0d207a8de30`; a clean external consumer
resolved both packages to that exact Git commit and passed its API smoke test.

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

## Physical evidence and remaining gaps

- On an AYN Thor running Android 13, the production example selected only the
  synthetic `Documents/workspace_dart_probe` folder through the system picker.
  After the example package was force-stopped and relaunched, it restored the
  stored grant, listed the folder, and read the 39-byte synthetic sample with
  unverified revision stability. No user content, tree URI, or native document
  ID was recorded.
- Cloud-only, provider failure, revocation, moved/deleted entry, concurrent
  mutation, hard-kill acquisition-window, and every required iPhone local or
  cloud-provider row remain unverified.

Never add tree URIs, bookmark data, native document IDs, absolute user paths,
or file contents to this document.
