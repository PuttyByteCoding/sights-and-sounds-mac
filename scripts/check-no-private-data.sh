#!/usr/bin/env bash
# Fails when a library database or snapshot export is TRACKED by git.
#
# .gitignore keeps these files unstaged by default, but it does not protect
# against `git add -f` or a renamed file — this guard does. Real library
# data (media metadata, the tag vocabulary, filenames, v8 snapshots) is
# private and must never enter history; history is forever.
#
# Portable to bash 3.2. Run from anywhere inside the repo.
set -uo pipefail

cd "$(dirname "$0")/.."

hits=$(git ls-files | grep -Ei '\.(sqlite|sqlite-wal|sqlite-shm|db)$|(^|/)snapshot[^/]*\.json$' || true)

if [ -n "$hits" ]; then
  echo "check-no-private-data: FAILED — data files are tracked by git:"
  echo "$hits" | sed 's/^/  /'
  echo "Remove them from the index (git rm --cached) before committing."
  exit 1
fi

echo "check-no-private-data: clean"
