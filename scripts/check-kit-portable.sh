#!/usr/bin/env bash
# Keeps the Kit free of macOS-only UI frameworks.
#
# SightsAndSoundsKit is the part meant to carry over to the iOS, iPadOS
# and tvOS apps unchanged (Package.swift says "nothing platform-specific
# lives here"). Nothing compiles it for those platforms yet, so drift is
# invisible until someone tries. This fails the build when the Kit
# imports AppKit or SwiftUI, or names an AppKit type.
#
# Not covered: `Process` (the external-tool layer). It is macOS-only too,
# and moving it out of the Kit is a separate decision.
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
KIT="$ROOT/Sources/SightsAndSoundsKit"

# Comment lines are skipped: explaining why AppKit is not used is fine.
hits=$(grep -rnE '^[[:space:]]*import (AppKit|SwiftUI)\b|\bNS(Image|BitmapImageRep|Workspace|Color|Font|Pasteboard|View|Window)\b' "$KIT" \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)
if [ -n "$hits" ]; then
    echo "$hits"
    echo "check-kit-portable: the Kit must not use AppKit or SwiftUI — see the comment in this script."
    exit 1
fi
echo "check-kit-portable: clean"
