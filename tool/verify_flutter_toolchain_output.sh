#!/usr/bin/env bash
# Rejects Flutter toolchain diagnostics that belong to this repository.
set -euo pipefail

if [[ $# != 2 || ( $1 != android && $1 != ios ) ]]; then
  echo "usage: $0 <android|ios> <build-log>" >&2
  exit 64
fi
platform=$1
log=$2
allowlist=${WORKSPACE_TOOLCHAIN_WARNING_ALLOWLIST:-"$(dirname "$0")/flutter_toolchain_warning_allowlist.txt"}
[[ -s "$log" ]] || { echo "build log is empty" >&2; exit 1; }
grep -Eq '(BUILD SUCCESSFUL|Built .*\.apk|Built .*\.app|✓ Built)' "$log" || {
  echo "build log has no success marker" >&2; exit 1;
}

fail_owned() {
  echo "repository-owned $platform toolchain diagnostic: $1" >&2
  exit 1
}

if [[ $platform == android ]]; then
  if grep -A30 -E 'plugins that apply Kotlin Gradle Plugin|apply Kotlin Gradle Plugin' "$log" | grep -Eq '(^|[[:space:],`])workspace_flutter([[:space:],`]|$)'; then
    fail_owned 'workspace_flutter applies Kotlin Gradle Plugin'
  fi
  if grep -Eqi '(:workspace_flutter|:app).*(deprecated|Kotlin Gradle Plugin)|(deprecated|Kotlin Gradle Plugin).*( :workspace_flutter|:app)' "$log"; then
    fail_owned 'a repository Gradle project uses deprecated KGP'
  fi
else
  if grep -A30 -E 'plugins do not support Swift Package Manager|Swift Package Manager support' "$log" | grep -Eq '(^|[[:space:],`])workspace_flutter([[:space:],`]|$)'; then
    fail_owned 'workspace_flutter lacks SwiftPM support'
  fi
  if grep -Eqi 'Plugin workspace_flutter .*Swift Package Manager|workspace_flutter.*FlutterFramework' "$log"; then
    fail_owned 'workspace_flutter SwiftPM manifest is invalid'
  fi
fi

# A listed warning is allowed only when every non-owned listed module has an
# exact, current row: platform|module|locked-version|upstream-url|YYYY-MM-DD.
while IFS= read -r module; do
  [[ -z "$module" || $module == workspace_flutter || $module == :app ]] && continue
  row=$(awk -F'|' -v p="$platform" -v m="$module" '$1 == p && $2 == m { print; exit }' "$allowlist" 2>/dev/null || true)
  [[ -n "$row" ]] || { echo "unallowlisted external $platform warning: $module" >&2; exit 1; }
  IFS='|' read -r row_platform row_module locked_version issue_url review_by extra <<<"$row"
  [[ $row_platform == "$platform" && $row_module == "$module" && -n $locked_version && $issue_url =~ ^https:// && -z $extra ]] || {
    echo "malformed warning allowlist row: $row" >&2; exit 1;
  }
  [[ $review_by =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && [[ $review_by > $(date -u +%F) ]] || {
    echo "expired or malformed warning allowlist row: $row" >&2; exit 1;
  }
done < <(grep -A30 -E 'plugins that apply Kotlin Gradle Plugin|plugins do not support Swift Package Manager' "$log" | sed -nE 's/^[[:space:]]*[-*•][[:space:]]*`?([^`,[:space:]]+)`?.*/\1/p')
