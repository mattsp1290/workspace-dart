#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/workspace-ci-policy.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/clean-pub.log" <<'EOF'
Publishing workspace 0.1.0 to https://pub.dev:
├── lib
└── pubspec.yaml
Validating package...
Package has 0 warnings.
EOF
"$root/tool/verify_pub_dry_run_output.sh" "$tmp/clean-pub.log"
printf '%s\n' 'Publishing workspace' '.dart_tool/cache' 'Validating package...' 'Package has 0 warnings.' > "$tmp/bad-pub.log"
if "$root/tool/verify_pub_dry_run_output.sh" "$tmp/bad-pub.log"; then
  echo 'denied archive fixture passed' >&2; exit 1
fi

printf '%s\n' 'BUILD SUCCESSFUL' 'Your app uses the following plugins that apply Kotlin Gradle Plugin:' ' - workspace_flutter' > "$tmp/owned-android.log"
if "$root/tool/verify_flutter_toolchain_output.sh" android "$tmp/owned-android.log"; then
  echo 'owned Android warning fixture passed' >&2; exit 1
fi
printf '%s\n' '✓ Built build/ios/iphoneos/Runner.app' 'The following plugins do not support Swift Package Manager:' ' - workspace_flutter' > "$tmp/owned-ios.log"
if "$root/tool/verify_flutter_toolchain_output.sh" ios "$tmp/owned-ios.log"; then
  echo 'owned iOS warning fixture passed' >&2; exit 1
fi
printf '%s\n' 'BUILD SUCCESSFUL' 'harmless output' > "$tmp/clean-build.log"
"$root/tool/verify_flutter_toolchain_output.sh" android "$tmp/clean-build.log"

printf '%s\n' 'BUILD SUCCESSFUL' 'Your app uses the following plugins that apply Kotlin Gradle Plugin:' ' - external_plugin' > "$tmp/external-android.log"
if "$root/tool/verify_flutter_toolchain_output.sh" android "$tmp/external-android.log"; then
  echo 'unallowlisted external warning fixture passed' >&2; exit 1
fi
printf '%s\n' 'android|external_plugin|1.2.3|https://example.invalid/issue|2099-01-01' > "$tmp/allowlist"
WORKSPACE_TOOLCHAIN_WARNING_ALLOWLIST="$tmp/allowlist" \
  "$root/tool/verify_flutter_toolchain_output.sh" android "$tmp/external-android.log"
printf '%s\n' 'android|external_plugin|1.2.3|https://example.invalid/issue|2000-01-01' > "$tmp/expired-allowlist"
if WORKSPACE_TOOLCHAIN_WARNING_ALLOWLIST="$tmp/expired-allowlist" \
  "$root/tool/verify_flutter_toolchain_output.sh" android "$tmp/external-android.log"; then
  echo 'expired external warning fixture passed' >&2; exit 1
fi
printf '%s\n' 'android|external_plugin|||2099-01-01' > "$tmp/malformed-allowlist"
if WORKSPACE_TOOLCHAIN_WARNING_ALLOWLIST="$tmp/malformed-allowlist" \
  "$root/tool/verify_flutter_toolchain_output.sh" android "$tmp/external-android.log"; then
  echo 'malformed external warning fixture passed' >&2; exit 1
fi

mkdir -p "$tmp/junit"
cat > "$tmp/junit/result.xml" <<'EOF'
<testsuite tests="1" failures="0" errors="0"><testcase name="WorkspaceProtocolTest"/></testsuite>
EOF
"$root/tool/verify_native_test_results.sh" junit "$tmp/junit" WorkspaceProtocolTest

cp "$root/packages/workspace_flutter/example/ios/Runner.xcodeproj/project.pbxproj" "$tmp/Runner.pbxproj"
"$root/tool/disable_ios_swiftpm_linkage.rb" "$tmp/Runner.pbxproj"
! rg -q 'FlutterGeneratedPluginSwiftPackage|FlutterFramework' "$tmp/Runner.pbxproj"

cocoapods_job=$(sed -n '/flutter-ios-cocoapods:/,/^$/p' "$root/.github/workflows/ci.yml")
grep -Fq 'Remove generated SwiftPM linkage in this CocoaPods checkout' <<<"$cocoapods_job"
grep -Fq 'Install CocoaPods for the direct XCTest host' <<<"$cocoapods_job"
grep -Fq -- '-parallel-testing-enabled NO' <<<"$cocoapods_job"
grep -Fq 'RunnerTests/testA01A02L01R01R02R03ControlledRootTraversesTheProductionHandler()' <<<"$cocoapods_job"
xctest_line=$(grep -n 'Run linked production-plugin XCTest host' <<<"$cocoapods_job" | cut -d: -f1)
conformance_line=$(grep -n 'Run registered and fixture iOS conformance' <<<"$cocoapods_job" | cut -d: -f1)
reset_line=$(grep -n 'Restore the normal CocoaPods XCTest host after Flutter conformance' <<<"$cocoapods_job" | cut -d: -f1)
test "$conformance_line" -lt "$reset_line"
test "$reset_line" -lt "$xctest_line"
grep -Fq 'flutter clean' <<<"$cocoapods_job"
grep -Fq 'flutter pub get --enforce-lockfile' <<<"$cocoapods_job"

android_job=$(sed -n '/flutter-android:/,/^$/p' "$root/.github/workflows/ci.yml")
grep -Fq 'Install the Android emulator PulseAudio runtime' <<<"$android_job"
grep -Fq 'sudo apt-get install --yes libpulse0' <<<"$android_job"
grep -Fq 'Enable KVM for the Android emulator' <<<"$android_job"
grep -Fq 'test -e /dev/kvm' <<<"$android_job"
grep -Fq '99-kvm4all.rules' <<<"$android_job"
grep -Fq 'emulator-options: -no-window -no-snapshot -noaudio -no-boot-anim -camera-back none -gpu swiftshader_indirect' <<<"$android_job"
grep -Fq 'disable-animations: true' <<<"$android_job"

swiftpm_job=$(sed -n '/flutter-ios-swiftpm:/,/^$/p' "$root/.github/workflows/ci.yml")
grep -Fq 'mv Podfile Podfile.cocoapods' <<<"$swiftpm_job"
grep -Fq 'swift package show-dependencies' <<<"$swiftpm_job"
grep -Fq 'select(.isAvailable == true and (.name | startswith("iPhone")))' <<<"$swiftpm_job"
