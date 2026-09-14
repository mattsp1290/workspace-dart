# Native feasibility evidence

Evidence date: 2026-09-13. The mobile-access implementation is committed as
`c3a24983155b2dc19746072c3accefaf8bc0dd1b`; the toolchain and physical-provider
evidence below applies to that implementation. The earlier published automated
baseline, `d3de2811958768cef428307c3bb0d0d207a8de30`, also proved that a clean
external consumer could resolve both packages at one immutable Git commit and
pass its API smoke test. CI now runs that consumer proof as a required check
against the pull request's reachable head commit (or the pushed commit), so a
release claim requires its successful result for the final branch revision.

## Toolchain

- Flutter 3.47.1 stable and Dart 3.13.1.
- Xcode 26.2 on the pinned macOS 26 runner. The plugin deployment target is
  iOS 18.2; CI behavior runs on the iOS 26.2 simulator runtime.
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
- The pure-Dart `workspace` package passes `dart pub publish --dry-run` with
  zero warnings. This is archive validation only; no publish or ownership
  claim is made.

## Flutter package publication deferral

`workspace_flutter` remains `publish_to: none`. Its updated 2026-09-13
`flutter pub publish --dry-run` exits 65 solely because of the required
`workspace` path dependency. The package now supplies its license, repository,
Flutter SDK floor, changelog, and analyzer-clean public Dart sources. The
dependency is intentionally still a path source because pub.dev's
`workspace` 0.1.0 is an unrelated layout package. A future publication gate is
unblocked only by a maintainer-approved, unclaimed core package name plus its
repository-wide import/API migration, or an owned hosted package identity.
Until then Git subdirectory dependencies at one immutable ref are the supported
distribution mechanism.

## Toolchain warning policy

Repository-owned Android configuration uses Flutter Built-in Kotlin with the
Flutter 3.44/Dart 3.12 package floor; CI validates it with Flutter 3.47.1,
Java 21, API 35 emulator, and compile SDK 35. iOS uses one Swift source tree
for CocoaPods and Swift Package Manager. CI rejects any Kotlin or SwiftPM
diagnostic attributed to `workspace_flutter` or `:app`. There are currently no
third-party warning allowlist rows; one can be added only with exact locked
version, upstream issue, and a future review date after updating dependencies.

Flutter 3.47.1 cannot yet apply its Gradle plugin with AGP 9.1 and
`android.newDsl=true`: it casts `ApplicationExtension` to the removed
`AbstractAppExtension` before compilation. The example therefore retains only
`android.newDsl=false` as a Flutter/AGP compatibility switch. Flutter 3.47.1
also misclassifies AGP 9.1's Built-in Kotlin 2.2.10 runtime as an old project
KGP and rejects it against its 2.2.20 validator floor. CI uses
`--android-skip-build-dependency-validation` only for that incorrect version
gate; it keeps `android.builtInKotlin=true`, removes every project-applied KGP,
and rejects any emitted repository-owned KGP warning. Direct Gradle native
test tasks use the equivalent `-PskipDependencyChecks=true`. Reevaluate both
compatibility workarounds when a fixed Flutter release supports AGP 9's new DSL
and recognizes AGP 9.1's bundled Kotlin.

On the current macOS Swift 6 toolchain, `swift test` accepts
`--xunit-output` but does not write XML for this XCTest package. CI retains
the option and verifies a fresh captured XCTest log instead: nonzero execution,
zero failures, and the stable protocol sentinel. Revisit this fallback when
Swift restores the xUnit artifact.

## Physical evidence and remaining gaps

| Device/provider | Completed physical evidence | Remaining release evidence |
| --- | --- | --- |
| AYN Thor, Android 13 local SAF | Selected the synthetic folder, then after force-stop/relaunch restored, listed, and read its fixture. The registered native fixture suite passed 28 cases and controlled-provider instrumentation passed five cases. | Cloud provider, revocation, moved/deleted, mutation, acquisition-window, cancellation, and resource balance. |
| iPhone 16 Pro, iOS 26.6.1 local Files | Selected/restarted/restored/listed/read a synthetic file; a moved folder returned `permissionLost`; a selected folder whose sole fixture was deleted listed empty. | Provider failure/revocation, mutation, acquisition-window, cancellation, and resource balance. |
| iPhone 16 Pro, iOS 26.6.1 iCloud Drive | Selected/listed/read a synthetic file and, after external termination plus Flutter-tool relaunch, restored/relisted/reread it with `unverified` stability. | Offline-only/provider failure/revocation, mutation, acquisition-window, cancellation, and resource balance. |

- On an AYN Thor running Android 13, the production example selected only the
  synthetic `workspace_dart_probe` folder through the system picker. After the
  example package was force-stopped and relaunched, it restored the stored
  grant, listed the folder, and read the 37-byte synthetic sample with
  unverified revision stability. No user content, tree URI, or native document
  ID was recorded.
- The user approved a connected iPhone 16 Pro (iPhone17,1) as the physical iOS
  evidence device in place of the originally planned iPhone 12. On iOS 26.6.1,
  the Flutter-debug example selected only the synthetic
  `workspace_dart_probe` folder through the system picker. Following external
  termination and relaunch through Flutter tooling, it restored the grant,
  listed the folder, and read the 456-byte synthetic Markdown file with
  unverified revision stability. No user content, bookmark data, document ID,
  or absolute path was recorded.
- On that same iPhone, renaming the selected synthetic folder through Files
  caused a later restore to return `permissionLost`. The adapter therefore
  failed closed rather than reporting an empty workspace or following a
  location by path.
- After reselecting that synthetic folder and deleting its only synthetic
  Markdown file, the example listed zero entries and did not attempt a read.
  This records physical empty-directory behavior after a file deletion; the
  controlled native fixture separately verifies stale issued-reference failure.
- In an iCloud Drive synthetic folder, the same iPhone selected, listed, and
  read a 456-byte synthetic Markdown file. After external termination and
  relaunch through Flutter tooling, it restored, relisted, and reread that file
  with `unverified` revision stability. This is physical iCloud Drive evidence,
  not a claim that the file was offline-only.
- After the selected iCloud Drive fixture was edited from 456 to 482 bytes,
  a later restore/list/read observed 482 bytes with `unverified` stability.
  The adapter therefore exposes the observed slice without claiming a coherent
  revision across the mutation.
- Provider failure, revocation, hard-kill acquisition-window, cancellation,
  and resource-balance rows remain unverified and are deferred by the
  maintainer for a later device-qualification pass. They remain release gates;
  this document does not treat the current implementation as release-qualified.

Never add tree URIs, bookmark data, native document IDs, absolute user paths,
or file contents to this document.
