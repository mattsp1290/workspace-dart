#!/usr/bin/env bash
# Resolves both packages from one immutable remote ref without overrides.
set -euo pipefail

if [[ $# != 1 ]]; then
  echo "usage: $0 <immutable-commit-or-tag>" >&2
  exit 64
fi
ref=$1
repo=${WORKSPACE_DART_GIT_URL:-$(git -C "$(dirname "$0")/.." remote get-url origin)}
[[ -n "$repo" ]] || { echo "origin remote is required" >&2; exit 1; }
resolved=$(git ls-remote "$repo" "$ref" "${ref}^{}" | awk 'NR == 1 { print $1 }')
if [[ -z "$resolved" && $ref =~ ^[0-9a-f]{40}$ ]]; then
  resolved=$(git ls-remote "$repo" | awk -v wanted="$ref" '$1 == wanted { print $1; exit }')
fi
[[ $resolved =~ ^[0-9a-f]{40}$ ]] || {
  echo "ref is not reachable from the configured remote: $ref" >&2; exit 1;
}
temp=$(mktemp -d "${TMPDIR:-/tmp}/workspace-dart-consumer.XXXXXX")
trap 'rm -rf "$temp"' EXIT
mkdir -p "$temp/test"
cp "$(dirname "$0")/testdata/git_consumer_smoke/test/workspace_smoke_test.dart" "$temp/test/"
cat > "$temp/pubspec.yaml" <<EOF
name: workspace_dart_git_consumer
publish_to: none
environment:
  sdk: ^3.12.0
dependencies:
  flutter:
    sdk: flutter
  workspace:
    git:
      url: $repo
      ref: $resolved
      path: packages/workspace
  workspace_flutter:
    git:
      url: $repo
      ref: $resolved
      path: packages/workspace_flutter
dev_dependencies:
  flutter_test:
    sdk: flutter
EOF
! grep -q '^dependency_overrides:' "$temp/pubspec.yaml"
(cd "$temp" && flutter pub get && flutter test)
