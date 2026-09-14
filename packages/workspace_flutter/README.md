# workspace_flutter

This package provides the trusted vault seam and direct iOS/Android read-only
directory adapters. The example contains an app-private probe vault and device
journeys for selection and restart restoration.

Native builds and an Android registered-plugin smoke test pass. Do not treat
that evidence as proof of every provider or process-death scenario; consult the
repository support matrix before release use.

Native protocol checks run without a device:

```text
(cd example/android && JAVA_HOME="/path/to/jdk" ./gradlew :workspace_flutter:testDebugUnitTest)
(cd ios && swift test)
```

The example's registered-plugin protocol smoke suite runs the production
MethodChannel handler, rather than a mocked messenger:

```text
cd example
flutter test integration_test/native_conformance_test.dart -d <android-or-ios-device>
```

These checks cover request decoding only. They do not qualify a physical file
provider, picker flow, process restart, or resource-cleanup behavior.

## Toolchain and distribution

This plugin requires Flutter 3.44+ and Dart 3.12+. Its Android build uses
Flutter's Built-in Kotlin support. iOS supports both CocoaPods and Flutter
Swift Package Manager from the same production Swift sources.

`workspace_flutter` is distributed from this repository's immutable Git refs;
it is deliberately not publishable because its `workspace` path dependency
must not resolve to the unrelated `workspace` package on pub.dev.
