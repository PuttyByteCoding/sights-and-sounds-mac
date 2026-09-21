#!/usr/bin/env bash
# Fails when private data is TRACKED by git: a library database or snapshot
# export, an archive (which no guard can read inside), or a real home
# directory path in tracked text.
#
# .gitignore keeps these files unstaged by default, but it does not protect
# against `git add -f` or a renamed file — this guard does. Real library
# data (media metadata, the tag vocabulary, filenames, v8 snapshots) is
# private and must never enter history; history is forever.
#
# Portable to bash 3.2. Run from anywhere inside the repo.
set -uo pipefail

cd "$(dirname "$0")/.."

hits=$(git ls-files | grep -Ei '\.(sqlite3?|db)(-wal|-shm)?$|(^|/)snapshot[^/]*\.json$' || true)

if [ -n "$hits" ]; then
  echo "check-no-private-data: FAILED — data files are tracked by git:"
  echo "$hits" | sed 's/^/  /'
  echo "Remove them from the index (git rm --cached) before committing."
  exit 1
fi

# An archive is a box this guard and the terminology guard cannot see
# into. Nothing in the repo needs one.
archives=$(git ls-files | grep -Ei '\.(zip|tar|tgz|gz|bz2|xz|7z|rar|dmg)$' || true)
if [ -n "$archives" ]; then
  echo "check-no-private-data: FAILED — archives are tracked by git, and no guard can read inside one:"
  echo "$archives" | sed 's/^/  /'
  echo "Commit the files themselves, or keep the archive outside the repo."
  exit 1
fi

# A real home directory in tracked text names a real account and a real
# disk layout. Placeholders are fine; this file names them in its pattern.
homes=$(git ls-files -z \
  | xargs -0 grep -nIE '/Users/[A-Za-z0-9._-]+' 2>/dev/null \
  | grep -vE '/Users/(someone|runner|you|me|name|username|user|example|Shared)([^A-Za-z0-9._-]|$)' \
  | grep -v '^scripts/check-no-private-data\.sh:' || true)
if [ -n "$homes" ]; then
  echo "check-no-private-data: FAILED — a home directory path is in tracked text:"
  echo "$homes" | cut -c1-200 | sed 's/^/  /'
  echo "Write ~/… or a placeholder such as /Users/someone/… instead."
  exit 1
fi

echo "check-no-private-data: clean"
