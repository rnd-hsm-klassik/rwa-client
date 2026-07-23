#!/bin/sh
#
# Forwarder to ../../ci_scripts/ci_post_clone.sh, which holds the real logic.
#
# Apple's guidance on where ci_scripts must live is inconsistent for projects
# that are not at the repository root: some builds pick it up at the repo root,
# others only next to the .xcodeproj. This repo has the project in rwaClient/,
# so the directory exists in both places and whichever one Xcode Cloud probes
# runs the same script. Running it twice is harmless — it only writes files.
#
# Keep this a forwarder; do not duplicate logic here.

set -eu

exec "$(cd "$(dirname "$0")/../.." && pwd)/ci_scripts/ci_post_clone.sh" "$@"
