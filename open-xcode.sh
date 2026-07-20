#!/bin/sh
# Launch Xcode for rwa-client with XCODE_XCCONFIG_FILE set, so archives skip the
# slow libpd-ios install-strip (see strip-override.xcconfig for the full why).
#
# IMPORTANT: quit any already-running Xcode first. If an instance is already up,
# launching again just activates it WITHOUT this environment variable, and the
# override won't apply.
here="$(cd "$(dirname "$0")" && pwd)"
export XCODE_XCCONFIG_FILE="$here/strip-override.xcconfig"
XCODE_APP="${XCODE_APP:-/Applications/Xcode.app}"
exec "$XCODE_APP/Contents/MacOS/Xcode" "$here/rwaClient/rwaclient.xcodeproj"
