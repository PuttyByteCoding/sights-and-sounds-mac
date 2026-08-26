#!/usr/bin/env bash
# Terminology guard for the sights-and-sounds repo.
#
# Fails the build when a banned name from the old web app appears. See
# docs/terminology.md for the full ledger and the reasoning behind each entry.
#
# Two tiers:
#   ERRORS   — unambiguous identifiers. Any occurrence fails.
#   WARNINGS — patterns whose English word is legitimate; reported, never fatal.
#
# Deliberately NOT run in sights-and-sounds-migrator: that repo has to speak the
# old vocabulary to read a v8 snapshot, which is exactly why it lives apart.
#
# Portable to bash 3.2 (macOS stock shell) — no mapfile, no arrays required
# beyond literals.
#
# Usage:  ./scripts/check-terminology.sh [path]     (default: repo root)
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"

# Files worth checking. Add extensions as the repo grows. Prunes build and
# dependency directories.
list_files() {
  find "$ROOT" \
    \( -path '*/.git' -o -path '*/.build' -o -path '*/DerivedData' \
       -o -path '*/node_modules' -o -path '*/.swiftpm' \) -prune -o \
    -type f \( -name '*.swift' -o -name '*.m' -o -name '*.h' -o -name '*.sql' \
               -o -name '*.json' -o -name '*.plist' -o -name '*.md' \
               -o -name '*.yml' -o -name '*.yaml' -o -name '*.sh' \
               -o -name '*.strings' -o -name '*.pbxproj' \) -print0
}

FILE_COUNT=$(list_files | tr -dc '\0' | wc -c | tr -d ' ')
if [ "$FILE_COUNT" -eq 0 ]; then
  echo "check-terminology: no source files found under '$ROOT'"
  exit 0
fi

ERRORS='VideoOrganizer
Video Organizer
TagGroup
PropertyDefinition
TagPropertyValue
VideoPropertyValue
PropertyScope
PropertyDataType
VideoSet
Md5Backfill
Md5Failed
ThumbnailWarming
SAS_MEDIA_ROOT
sas_media_token'

# Extended regexes — the word is fine, these shapes are not.
WARNINGS='class[[:space:]]+Video\b
struct[[:space:]]+Video\b
enum[[:space:]]+Video\b
\bMd5\b
CREATE[[:space:]]+TABLE[[:space:]]+videos\b'

# This script and the reference docs name every banned term by design;
# exclude them from their own scan.
filter_own() {
  grep -v '/check-terminology\.sh:' \
    | grep -v '/terminology\.md:' \
    | grep -v '/replatform-brief\.'
}

fail=0
echo "check-terminology: scanning $FILE_COUNT files under '$ROOT'"

while IFS= read -r term; do
  [ -z "$term" ] && continue
  hits=$(list_files | xargs -0 grep -FnI -- "$term" 2>/dev/null | filter_own || true)
  if [ -n "$hits" ]; then
    echo
    echo "ERROR: banned term '$term'"
    echo "$hits" | sed 's/^/  /'
    fail=1
  fi
done <<EOT
$ERRORS
EOT

while IFS= read -r pat; do
  [ -z "$pat" ] && continue
  hits=$(list_files | xargs -0 grep -EnI -- "$pat" 2>/dev/null | filter_own || true)
  if [ -n "$hits" ]; then
    echo
    echo "WARNING: review '$pat' (see docs/terminology.md)"
    echo "$hits" | sed 's/^/  /'
  fi
done <<EOT
$WARNINGS
EOT

echo
if [ "$fail" -ne 0 ]; then
  echo "check-terminology: FAILED — see docs/terminology.md for replacements"
  exit 1
fi

echo "check-terminology: clean"
