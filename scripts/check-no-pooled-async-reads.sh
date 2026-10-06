#!/usr/bin/env bash
# Keeps async code off GRDB's async `read`.
#
# GRDB's async `read` takes one of a library's few reader connections and
# then waits for a thread of Swift's shared pool. Every library method is
# a blocking read, and async code calling one holds a shared-pool thread
# while it waits for a connection. Enough of both at once and each waits
# on the other forever: the app stopped after a Review purge set every
# window refreshing. Async code reads with `LibraryDatabase.read`, which
# goes through `asyncRead` and never holds a connection while waiting for
# the shared pool. See Sources/SightsAndSoundsKit/Database/LibraryDatabase+Reading.swift.
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"

# Comment lines are skipped, and so is the one place that explains it.
hits=$(grep -rnE 'await [A-Za-z_.()!?]*writer\.(read|unsafeRead)\b' "$ROOT/Sources" \
    | grep -v 'LibraryDatabase+Reading.swift' \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)
if [ -n "$hits" ]; then
    echo "$hits"
    echo "check-no-pooled-async-reads: use library.read { } from async code — see the comment in this script."
    exit 1
fi
echo "check-no-pooled-async-reads: clean"
