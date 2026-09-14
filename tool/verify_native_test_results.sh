#!/usr/bin/env bash
# Ensures native commands executed real tests and their stable protocol sentinel.
set -euo pipefail

if [[ $# != 3 ]]; then
  echo "usage: $0 <junit|swift-xunit|swift-output|xcresult> <result-path> <sentinel>" >&2
  exit 64
fi
kind=$1 result=$2 sentinel=$3
[[ -e "$result" ]] || { echo "native result is absent: $result" >&2; exit 1; }

case "$kind" in
  junit|swift-xunit)
    xml=$(find "$result" -type f \( -name '*.xml' -o -name '*.xunit' \) -print 2>/dev/null)
    [[ -n "$xml" ]] || { echo "no XML native result found" >&2; exit 1; }
    grep -Eq 'tests="[1-9][0-9]*"' $xml || { echo "no executed tests" >&2; exit 1; }
    ! grep -Eq '<(failure|error)([ >])' $xml || { echo "native test failure" >&2; exit 1; }
    total=$(sed -nE 's/.*tests="([0-9]+)".*/\1/p' $xml | awk '{ sum += $1 } END { print sum + 0 }')
    skipped=$(sed -nE 's/.*skipped="([0-9]+)".*/\1/p' $xml | awk '{ sum += $1 } END { print sum + 0 }')
    (( total > skipped )) || { echo "native suite is skipped-only" >&2; exit 1; }
    grep -Fq "$sentinel" $xml || { echo "native sentinel missing: $sentinel" >&2; exit 1; }
    ;;
  swift-output)
    grep -Eq 'Executed [1-9][0-9]* tests?, with 0 failures' "$result" || {
      echo "Swift output has no successful XCTest execution" >&2; exit 1;
    }
    grep -Fq "$sentinel" "$result" || { echo "Swift sentinel missing: $sentinel" >&2; exit 1; }
    ;;
  xcresult)
    command -v xcrun >/dev/null || { echo "xcrun required for xcresult" >&2; exit 1; }
    output=$(xcrun xcresulttool get test-results tests --path "$result")
    grep -Fq "$sentinel" <<<"$output" || { echo "XCTest sentinel missing: $sentinel" >&2; exit 1; }
    ! grep -Eqi '"result"[[:space:]]*:[[:space:]]*"(Failed|Skipped)"' <<<"$output" || { echo "failed or skipped XCTest" >&2; exit 1; }
    ;;
  *) echo "unknown result kind: $kind" >&2; exit 64 ;;
esac
