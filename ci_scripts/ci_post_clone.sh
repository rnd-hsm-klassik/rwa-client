#!/bin/sh
#
# Xcode Cloud post-clone hook.
#
# The build needs two gitignored files that only exist on developer machines:
#
#   rwaClient/.xcconfig                      DEVELOPMENT_TEAM for signing
#   rwaClient/src/Telemetry/Telemetry.plist  telemetry gateway config
#
# Telemetry.plist is in Copy Bundle Resources, so a missing file is a hard
# build failure, not a runtime fallback. This script materialises both from
# Xcode Cloud environment variables (App Store Connect > Xcode Cloud >
# Workflow > Environment). See README.md, "Xcode Cloud".
#
# Required environment variables:
#   DEVELOPMENT_TEAM         Apple Developer Team ID (plain)
#   TELEMETRY_BASE_URL       backend base URL, no trailing slash (plain)
#   TELEMETRY_DEVICE_ID      (optional) kiosk device id, e.g. hs-01 (plain)
#   TELEMETRY_INGEST_TOKEN   bearer token for /v1/batch (SECRET)

set -eu

log() { printf '[ci_post_clone] %s\n' "$*"; }
fail() { printf '[ci_post_clone] error: %s\n' "$*" >&2; exit 1; }

# Xcode Cloud always sets CI_PRIMARY_REPOSITORY_PATH. The walk-up is only a
# fallback so the script is testable locally.
find_repo_root() {
    d=$(cd "$(dirname "$0")" && pwd)
    while [ "$d" != "/" ]; do
        if [ -d "$d/rwaClient/rwaclient.xcodeproj" ]; then
            printf '%s\n' "$d"
            return 0
        fi
        d=$(dirname "$d")
    done
    return 1
}

REPO_ROOT="${CI_PRIMARY_REPOSITORY_PATH:-$(find_repo_root)}"
[ -n "$REPO_ROOT" ] || fail "could not locate the repository root"
[ -d "$REPO_ROOT/rwaClient/rwaclient.xcodeproj" ] || \
    fail "no rwaclient.xcodeproj under '$REPO_ROOT' — wrong repository root?"

log "repository root: $REPO_ROOT"

# --- validate up front, so we never write a half-populated config -----------
#
# A variable marked Secret in the workflow arrives empty if it was not granted
# to this workflow, which would otherwise produce a plist with an empty token
# and an app that builds fine but 401s against the backend. Fail loudly.
missing=""
for var in DEVELOPMENT_TEAM TELEMETRY_BASE_URL TELEMETRY_INGEST_TOKEN; do
    eval "value=\${$var:-}"
    [ -n "$value" ] || missing="$missing $var"
done
[ -z "$missing" ] || fail "unset or empty environment variable(s):$missing
Set them under App Store Connect > Xcode Cloud > Workflow > Environment.
Secret variables must be re-entered for each workflow that needs them."

# TELEMETRY_DEVICE_ID is optional, should be empty for real devices
DEVICE_ID="${TELEMETRY_DEVICE_ID:-}"

# --- rwaClient/.xcconfig ----------------------------------------------------
XCCONFIG="$REPO_ROOT/rwaClient/.xcconfig"
printf 'DEVELOPMENT_TEAM = %s\n' "$DEVELOPMENT_TEAM" > "$XCCONFIG"
log "wrote $XCCONFIG (DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM)"

# --- rwaClient/src/Telemetry/Telemetry.plist --------------------------------
TELEMETRY_DIR="$REPO_ROOT/rwaClient/src/Telemetry"
TEMPLATE="$TELEMETRY_DIR/Telemetry.example.plist"
PLIST="$TELEMETRY_DIR/Telemetry.plist"

[ -f "$TEMPLATE" ] || fail "missing template $TEMPLATE"
cp "$TEMPLATE" "$PLIST"

# plutil takes each value as its own argument, so tokens containing spaces or
# shell metacharacters survive intact (PlistBuddy -c would re-split them).
plutil -replace DeviceId               -string "$DEVICE_ID"              "$PLIST"
plutil -replace BaseURL                -string "$TELEMETRY_BASE_URL"     "$PLIST"
plutil -replace IngestToken            -string "$TELEMETRY_INGEST_TOKEN" "$PLIST"

# Verify what actually landed. TelemetryConfig.loadFromBundle() returns nil on
# any missing key and never validates the token, so catch it here instead.
plutil -lint "$PLIST" >/dev/null || fail "generated $PLIST is not a valid plist"
for key in DeviceId BaseURL IngestToken; do
    plutil -extract "$key" raw -o - "$PLIST" >/dev/null 2>&1 || \
        fail "generated plist is missing key '$key'"
done
token_len=$(plutil -extract IngestToken raw -o - "$PLIST" | tr -d '\n' | wc -c | tr -d ' ')
[ "$token_len" -gt 0 ] || fail "generated plist has an empty IngestToken"

log "wrote $PLIST"
log "  DeviceId=$DEVICE_ID BaseURL=$TELEMETRY_BASE_URL"
log "  IngestToken=<$token_len chars>"
log "done"
