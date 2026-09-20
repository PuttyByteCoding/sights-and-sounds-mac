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

cd "$ROOT" || exit 2

# Files worth checking. Add extensions as the repo grows.
#
# In a git checkout the list is what git TRACKS: that is what CI sees and
# what can be pushed. Walking the working tree instead also scanned dist/,
# editor state and local indexes, so a local run and CI disagreed. The
# design handoff's .html and .js are text too and are under the guard.
# Outside a checkout (a path argument), fall back to walking the folder.
wanted() {
  while IFS= read -r -d '' file; do
    case "$file" in
      *.swift|*.m|*.h|*.sql|*.json|*.plist|*.md|*.yml|*.yaml|*.sh|*.strings|*.pbxproj|*.html|*.js|*.css|*.txt)
        printf '%s\0' "$file" ;;
    esac
  done
}

list_files() {
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git ls-files -z | wanted
  else
    find . \
      \( -path '*/.git' -o -path '*/.build' -o -path '*/DerivedData' \
         -o -path '*/node_modules' -o -path '*/.swiftpm' \) -prune -o \
      -type f -print0 | sed -e 's#\./##g' | wanted
  fi
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
# The design handoff's index states the rule itself ("never TagGroup or
# Property"), so it names a banned term for the same reason the ledger
# does. Only the index — the sixteen specs stay under the guard, where a
# real slip would be caught.
#
# Anchored to the exact paths. As substrings they exempted any file that
# happened to be called terminology.md, anywhere.
filter_own() {
  grep -v '^scripts/check-terminology\.sh:' \
    | grep -v '^docs/terminology\.md:' \
    | grep -v '^docs/replatform-brief\.[^/:]*:' \
    | grep -v '^docs/design/README\.md:'
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
