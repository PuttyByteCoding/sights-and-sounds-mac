#!/usr/bin/env bash
# Run the tests.
#
#   ./scripts/run-tests.sh                 every test
#   ./scripts/run-tests.sh --merge-gate    only what a merge waits for
#   ./scripts/run-tests.sh [--merge-gate] <filter>
#                                          the tests whose names match
#
# Every test is the default, and it is what to run on your own Mac
# between builds. A merge waits for fewer: CI leaves out the tests that
# write a real video (they are marked `.writesVideo`; see
# Tests/*/MergeGate.swift for why), and runs the rest one at a time, so
# that a test doing heavy work cannot starve the others on a machine
# with three cores. --merge-gate is exactly what CI runs, for when a
# pull request's check fails and you want to see it here.
#
# Portable to bash 3.2. Run from anywhere inside the repo.
set -uo pipefail

cd "$(dirname "$0")/.."

order=()
if [ "${1:-}" = "--merge-gate" ]; then
    shift
    export SAS_MERGE_GATE=1
    order=(--no-parallel)
    echo "run-tests: the merge gate — one at a time, without the tests that write a real video"
else
    # Set in the shell or not, a plain run is every test.
    unset SAS_MERGE_GATE
    echo "run-tests: every test"
fi

if [ $# -gt 0 ]; then
    exec swift test ${order[@]+"${order[@]}"} --filter "$1"
fi
exec swift test ${order[@]+"${order[@]}"}
