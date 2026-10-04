#!/usr/bin/env bash
# The app's direct use of the database and the job runner can only go down.
#
#   ./scripts/check-service-boundary.sh            check against the baseline
#   ./scripts/check-service-boundary.sh --update   rewrite the baseline
#
# A window is to be given a `LibraryService`, never the database, so that
# the library it shows can be one another Mac holds (see
# docs/superpowers/specs/2026-10-03-remote-library-design.md). The windows
# are moving onto the service one at a time, and until they all have, the
# app target still calls `LibraryDatabase` and `JobRunner` in many places.
#
# This counts those calls per file and compares them with
# scripts/service-boundary-baseline.txt. A file above its number fails:
# new code goes through the service. A file below it is reported, not
# failed — lower the baseline in the same change (`--update`), so the
# number cannot creep back up later.
#
# What is counted, on lines that are not comments:
#   library.something(      a call on the database, however it was reached
#   .writer.read / .write   a query written out in the app target
#   runner.something(       a call on the job runner
#
# Portable to bash 3.2. Run from anywhere inside the repo.
set -uo pipefail

cd "$(dirname "$0")/.."
BASELINE=scripts/service-boundary-baseline.txt
APP=Sources/SightsAndSoundsApp
PATTERN='library\.[a-zA-Z]+\(|\.writer\.(read|write)|[rR]unner\.[a-zA-Z]+\('

count() {
    grep -vE '^[[:space:]]*//' "$1" | grep -cE "$PATTERN" || true
}

if [ "${1:-}" = "--update" ]; then
    : > "$BASELINE"
    find "$APP" -name '*.swift' | LC_ALL=C sort | while IFS= read -r file; do
        n=$(count "$file")
        [ "$n" -gt 0 ] && printf '%s\t%s\n' "$n" "$file" >> "$BASELINE"
    done
    total=$(awk -F'\t' '{ sum += $1 } END { print sum + 0 }' "$BASELINE")
    echo "check-service-boundary: baseline rewritten — $total direct uses in $(wc -l < "$BASELINE" | tr -d ' ') files"
    exit 0
fi

if [ ! -f "$BASELINE" ]; then
    echo "check-service-boundary: FAILED — $BASELINE is missing"
    exit 1
fi

failed=0
lower=0
total=0
while IFS= read -r file; do
    n=$(count "$file")
    total=$((total + n))
    allowed=$(awk -F'\t' -v f="$file" '$2 == f { print $1 }' "$BASELINE")
    allowed=${allowed:-0}
    if [ "$n" -gt "$allowed" ]; then
        echo "$file: $n direct uses of the database or runner, baseline $allowed"
        failed=1
    elif [ "$n" -lt "$allowed" ]; then
        echo "$file: $n, below its baseline of $allowed"
        lower=1
    fi
done < <(find "$APP" -name '*.swift' | LC_ALL=C sort)

if [ "$failed" -ne 0 ]; then
    echo "check-service-boundary: FAILED — ask the window's LibraryService instead; see the comment in this script."
    exit 1
fi
if [ "$lower" -ne 0 ]; then
    echo "check-service-boundary: clean, and the baseline can come down — run with --update and commit it"
    exit 0
fi
echo "check-service-boundary: clean ($total direct uses left)"
