#!/usr/bin/env bash
# Validates the archive listing emitted by `dart pub publish --dry-run`.
set -euo pipefail

if [[ $# != 1 ]]; then
  echo "usage: $0 <publish-dry-run-log>" >&2
  exit 64
fi
log=$1
[[ -s "$log" ]] || { echo "publish dry-run log is empty" >&2; exit 1; }
grep -Fq 'Publishing workspace ' "$log" || { echo "missing archive listing" >&2; exit 1; }
grep -Fq 'Validating package...' "$log" || { echo "missing validation completion" >&2; exit 1; }
grep -Fq 'Package has 0 warnings.' "$log" || { echo "publish validation has warnings or was truncated" >&2; exit 1; }

# These names are never valid package archive inputs. Match path components,
# rather than loose words, so documentation about the policy remains valid.
if grep -E '(^|[[:space:]│])([^[:space:]│]*/)?(\.dart_tool|build|\.build|\.swiftpm|Pods)(/|[[:space:]│])|(^|[[:space:]│])(\.env|\.env\.[^[:space:]│]+|credentials[^[:space:]│]*|.*grant[^[:space:]│]*)([[:space:]│]|$)' "$log"; then
  echo "archive contains a denied generated or sensitive path" >&2
  exit 1
fi
