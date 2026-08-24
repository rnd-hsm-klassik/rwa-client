#!/bin/bash
# deploy_games.sh: push RWA game folders over USB into the Player's Documents
# directory on connected iPhones. iOS 17+ phones are driven with devicectl
# (Xcode 15+); older phones (iOS 16) with pymobiledevice3 over the classic
# lockdown/AFC protocol (install it once with:  brew install pipx &&
# pipx install pymobiledevice3).
#
# A game folder is a directory containing a <name>.rwa plus its assets/ folder
# (same layout as rwaGames/rwatest). Each game lands in Documents/<name>/ of
# com.fhnw.rwa.player, where GameManager picks it up on the next Games-tab scan.
#
# Usage:
#   ./deploy_games.sh [-an] [-s <settings-plist>] <games-folder> [device ...]
#   ./deploy_games.sh [-an] -s <settings-plist> [device ...]
#
#   <games-folder>  either a single game folder, or a folder whose immediate
#                   subdirectories are game folders (all are deployed).
#                   Omit it (second form) for a settings-only run: no game is
#                   copied, only each phone's provisioning entry is pushed.
#   [device ...]    device names or UDIDs; default: every paired USB-connected
#                   device (iOS 17+ via devicectl, iOS 16 via pymobiledevice3)
#   -a              also target Wi-Fi-connected (network) devices (iOS 17+
#                   only; the iOS 16 path always uses USB)
#   -n              dry run: show what would be copied where, copy nothing
#   -s <plist>      per-phone settings: a single plist dictionary keyed by
#                   hardware UDID; each phone's matching entry is pushed as
#                   Documents/player-settings.plist and applied to the app's
#                   settings at next launch (ProvisioningLoader). See
#                   provisioning.example.plist for the format.
#
# Phones must be unlocked while deploying (devicectl mounts the developer disk
# image first; a locked phone fails with CoreDeviceError 12040).
#
# Deploys only add and overwrite; stale games are NOT removed. To delete a
# game, use the Files app on the phone (On My iPhone > RWA Player), Finder's
# file-sharing pane, or (any iOS version):
#   pymobiledevice3 apps rm com.fhnw.rwa.player "Documents/<game>" --udid <udid>
# devicectl's --remove-existing-content flag is NOT a per-folder mirror: it
# wipes the ENTIRE app container (all games, the app's settings in
# Library/Preferences, pending telemetry) before copying.
#
# Note: the in-app "fetch new games" flow wipes Documents entirely before
# downloading. Don't mix it with USB deployment on the same device.

set -euo pipefail

BUNDLE_ID="com.fhnw.rwa.player"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# pymobiledevice3 (optional, needed for iOS 16 phones): find the CLI and the
# python of its venv, which runs deploy_games_afc.py with the library.
PMD3_BIN=$(command -v pymobiledevice3 || true)
if [ -z "$PMD3_BIN" ] && [ -x "$HOME/.local/bin/pymobiledevice3" ]; then
    PMD3_BIN="$HOME/.local/bin/pymobiledevice3"
fi
PMD3_PY=""
if [ -n "$PMD3_BIN" ]; then
    # pipx entry points carry the venv python on line 2 ('''exec' '<python>' ...),
    # plain pip installs in a normal #! shebang.
    PMD3_PY=$(sed -n "2s/^'''exec' '\([^']*\)'.*/\1/p" "$PMD3_BIN")
    [ -n "$PMD3_PY" ] || PMD3_PY=$(sed -n '1s|^#!\(.*python.*\)$|\1|p' "$PMD3_BIN")
    if [ ! -x "$PMD3_PY" ]; then
        PMD3_BIN=""
        PMD3_PY=""
    fi
fi

usage() { sed -n '2,37p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

include_network=false
dry_run=false
settings_plist=""
while getopts "ans:h" opt; do
    case $opt in
        a) include_network=true ;;
        n) dry_run=true ;;
        s) settings_plist=$OPTARG ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

# The games folder is optional when -s is given (settings-only run): with no
# games folder every positional argument is a device. Tell the two apart by
# whether the first argument is a directory, and refuse anything that looks
# like a mistyped path so a typo never silently becomes a device name.
src=""
if [ -n "$settings_plist" ] && { [ $# -eq 0 ] || [ ! -d "$1" ]; }; then
    if [ $# -ge 1 ] && case $1 in */*|.*|~*) true ;; *) false ;; esac; then
        echo "error: '$1' is not a directory" >&2
        exit 1
    fi
else
    [ $# -ge 1 ] || usage
    src=$1
    shift
    [ -d "$src" ] || { echo "error: '$src' is not a directory" >&2; exit 1; }
fi
if [ -n "$settings_plist" ]; then
    plutil -lint "$settings_plist" >/dev/null || { echo "error: settings file '$settings_plist' is not a valid plist" >&2; exit 1; }
fi

workdir=$(mktemp -d /tmp/deploy_games.XXXXXX)
trap 'rm -rf "$workdir"' EXIT

# --- collect game folders -----------------------------------------------------

games=()   # absolute paths of game folders to deploy (empty on a settings-only run)
if [ -n "$src" ]; then
    shopt -s nullglob
    rwa_here=("$src"/*.rwa)
    if [ ${#rwa_here[@]} -gt 0 ]; then
        games=("$src")
    else
        for d in "$src"/*/; do
            d=${d%/}
            inner=("$d"/*.rwa)
            if [ ${#inner[@]} -gt 0 ]; then
                games+=("$d")
            else
                echo "warning: skipping '$(basename "$d")': no .rwa file in it" >&2
            fi
        done
    fi
    shopt -u nullglob

    [ ${#games[@]} -gt 0 ] || { echo "error: no game folders (with a .rwa) found under '$src'" >&2; exit 1; }
fi

# --- collect target devices ---------------------------------------------------
# iOS 17+ phones come from devicectl (CoreDevice); iOS 16 phones are invisible
# to devicectl and come from pymobiledevice3's usbmux listing instead.

xcrun devicectl list devices --quiet --json-output "$workdir/devices.json" >/dev/null
if [ -n "$PMD3_BIN" ]; then
    "$PMD3_BIN" usbmux list --usb > "$workdir/usbmux.json" 2>/dev/null || echo '[]' > "$workdir/usbmux.json"
else
    echo '[]' > "$workdir/usbmux.json"
fi

discovered=()  # "udid<TAB>name<TAB>tool" (tool: dctl | afc)
while IFS= read -r line; do
    discovered+=("$line")
done < <(python3 - "$workdir/devices.json" "$workdir/usbmux.json" "$include_network" <<'PY'
import json, sys
dctl = json.load(open(sys.argv[1]))["result"]["devices"]
mux = json.load(open(sys.argv[2]))
include_network = sys.argv[3] == "true"
for d in dctl:
    conn = d.get("connectionProperties", {})
    transport = conn.get("transportType")  # absent when unavailable
    if conn.get("pairingState") != "paired":
        continue
    if transport == "wired" or (include_network and transport == "localNetwork"):
        # Prefer the hardware UDID (stable, used in the settings plist and
        # accepted by devicectl --device) over the CoreDevice identifier.
        udid = d.get("hardwareProperties", {}).get("udid", d["identifier"])
        print(f'{udid}\t{d["deviceProperties"]["name"]}\tdctl')
for d in mux:
    try:
        major = int(str(d.get("ProductVersion", "")).split(".")[0])
    except ValueError:
        continue
    if major < 17:  # 17+ phones are handled (better) by devicectl above
        udid = d["Identifier"]
        print(f'{udid}\t{d.get("DeviceName", udid)}\tafc')
PY
)

devices=()
if [ $# -gt 0 ]; then
    # Explicit devices: use the discovered entry when we have one (so iOS 16
    # phones get the afc tool), otherwise hand the name through to devicectl.
    for dev in "$@"; do
        found=""
        for entry in "${discovered[@]}"; do
            udid=${entry%%	*}
            name=$(printf '%s' "$entry" | cut -f2)
            if [ "$dev" = "$udid" ] || [ "$dev" = "$name" ]; then
                found=$entry
                break
            fi
        done
        devices+=("${found:-$dev	$dev	dctl}")
    done
else
    devices=("${discovered[@]:-}")
    if [ ${#devices[@]} -eq 0 ] || [ -z "${devices[0]}" ]; then
        echo "error: no paired USB-connected devices found (use -a to include Wi-Fi devices)" >&2
        [ -n "$PMD3_BIN" ] || echo "note: pymobiledevice3 is not installed - iOS 16 phones cannot be discovered" >&2
        exit 1
    fi
fi

for entry in "${devices[@]}"; do
    if [ "${entry##*	}" = "afc" ] && [ -z "$PMD3_PY" ]; then
        echo "error: $(printf '%s' "$entry" | cut -f2) needs pymobiledevice3 (pipx install pymobiledevice3)" >&2
        exit 1
    fi
done

# --- stage games --------------------------------------------------------------
# APFS-clone each game folder (instant, no extra disk space), then strip macOS
# junk and the Creator's working files (tilecache/, tmp/, undo/, layouts.ini)
# so they never land on the device. Cloning preserves mtimes, keeping
# devicectl's skip-unmodified behaviour intact.

mkdir -p "$workdir/stage"
for game in ${games[@]+"${games[@]}"}; do
    stage="$workdir/stage/$(basename "$game")"
    cp -Rc "$game" "$stage"
    rm -rf "$stage/tilecache" "$stage/tmp" "$stage/undo" \
           "$stage/layouts.ini" "$stage/layout.ini"
    find "$stage" \( -name '.DS_Store' -o -name '._*' \) -delete
done

# --- deploy -------------------------------------------------------------------

if [ ${#games[@]} -gt 0 ]; then
    echo "Games:   ${games[*]/#*\//}"
else
    echo "Games:   none (settings-only run)"
fi
echo "Devices: $(printf '%s' "${devices[*]}" | cut -f2 | tr '\n' ' ')"
echo

failures=0
settings_pushed=0

# push <tool> <udid> <name> <local-path> <container-relative-destination>
push() {
    local ok=true
    if [ "$1" = "afc" ]; then
        local mode=push-file
        [ -d "$4" ] && mode=push-dir
        "$PMD3_PY" "$SCRIPT_DIR/deploy_games_afc.py" --udid "$2" --bundle "$BUNDLE_ID" \
            "$mode" "$4" "$5" > "$workdir/copy.log" 2>&1 || ok=false
    else
        xcrun devicectl device copy to --device "$2" \
            --source "$4" --destination "$5" \
            --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
            --user mobile > "$workdir/copy.log" 2>&1 || ok=false
    fi
    if $ok; then
        grep 'file(s) pushed' "$workdir/copy.log" || echo "    ok"
    else
        failures=$((failures + 1))
        if grep -qi "device is locked\|PasswordProtected" "$workdir/copy.log"; then
            echo "    FAILED: $3 is locked — unlock the phone and rerun." >&2
        else
            echo "    FAILED — output:" >&2
            tail -5 "$workdir/copy.log" | sed 's/^/      /' >&2
        fi
    fi
}

for entry in "${devices[@]}"; do
    udid=${entry%%	*}
    name=$(printf '%s' "$entry" | cut -f2)
    tool=${entry##*	}

    for game in ${games[@]+"${games[@]}"}; do
        gname=$(basename "$game")
        if $dry_run; then
            echo "[dry run] $gname -> $name ($udid, $tool) Documents/$gname"
        else
            echo "==> $gname -> $name"
            push "$tool" "$udid" "$name" "$workdir/stage/$gname" "Documents/$gname"
        fi
    done

    if [ -n "$settings_plist" ]; then
        entry="$workdir/settings-entry.plist"
        if ! plutil -extract "$udid" xml1 -o "$entry" "$settings_plist" >/dev/null 2>&1; then
            echo "warning: no settings entry for '$name' ($udid) in $settings_plist, skipping settings push" >&2
        elif $dry_run; then
            echo "[dry run] settings entry $udid -> $name Documents/player-settings.plist"
            settings_pushed=$((settings_pushed + 1))
        else
            echo "==> settings -> $name"
            push "$tool" "$udid" "$name" "$entry" "Documents/player-settings.plist"
            settings_pushed=$((settings_pushed + 1))
        fi
    fi
done

# A settings-only run that matched no phone did nothing at all.
if [ ${#games[@]} -eq 0 ] && [ $settings_pushed -eq 0 ]; then
    echo
    echo "error: no connected phone has an entry in $settings_plist, nothing was pushed." >&2
    echo "note: entries are keyed by hardware UDID (pymobiledevice3 usbmux list)." >&2
    exit 1
fi

$dry_run && exit 0
echo
if [ $failures -gt 0 ]; then
    echo "$failures deployment(s) failed." >&2
    exit 1
fi
if [ ${#games[@]} -gt 0 ]; then
    echo "Done. Relaunch RWA Player on each phone so it rescans Documents and applies pushed settings."
else
    echo "Done. Relaunch RWA Player on each phone so it applies the pushed settings."
fi
