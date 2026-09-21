#!/usr/bin/env bash
# Fails when building the package and its tests emits a compiler warning
# from this repo's own code.
#
#   ./scripts/check-build-warnings.sh
#
# The rule is "zero warnings", and until now only a person reading build
# output enforced it. Warnings from dependencies are not ours to fix and
# are ignored (SwiftPM already silences them).
#
# Caveat: the compiler only reports a warning when it compiles the file.
# On a warm .build an unchanged file says nothing, so a clean result is
# conclusive for the files this build compiled. CI builds cold, or from a
# cache that a passing run saved. For a conclusive local answer, run
# `swift package clean` first.
#
# Portable to bash 3.2. Run from anywhere inside the repo.
set -uo pipefail

cd "$(dirname "$0")/.."

log=$(mktemp)
trap 'rm -f "$log"' EXIT

swift build --build-tests 2>&1 | tee "$log"
status=${PIPESTATUS[0]}
if [ "$status" -ne 0 ]; then
  echo "check-build-warnings: FAILED — the build itself failed"
  exit "$status"
fi

# Strip colour codes, keep diagnostics, drop dependency checkouts and the
# indented source-context echo of the same warning.
hits=$(sed $'s/\x1b\\[[0-9;]*m//g' "$log" \
  | grep -E '^[^ |].*: warning: ' \
  | grep -v '/\.build/' \
  | sort -u || true)

if [ -n "$hits" ]; then
  echo
  echo "check-build-warnings: FAILED — the build must be warning-free:"
  echo "$hits" | sed 's/^/  /'
  exit 1
fi

echo "check-build-warnings: clean"
