#!/usr/bin/env bash
#
# Demo launcher for macOS_FSMetrics.
#
#   Scripts/demo.sh                 demo day: launch the installed app (<1s)
#   Scripts/demo.sh --setup         one-time: build, install to /Applications,
#                                   install default settings, seed chart
#                                   history, open Full Disk Access settings
#   Scripts/demo.sh --verify        confirm per-user metrics exist (FDA check)
#
# Flags for --setup:
#   --seed N          collection cycles used to seed chart history (default 8)
#   --with-agent      also install the LaunchAgent (Scripts/install-agent.sh)
#   --reset-settings  overwrite settings.json with config.example.json defaults
#                     (the previous file is backed up first)
#
# The installed bundle is never rebuilt by a plain `Scripts/demo.sh`: the app
# is ad-hoc signed, and TCC ties Full Disk Access grants to the code
# signature, so any rebuild silently revokes the grant and the folder
# permission prompts come back mid-demo. Updating means re-running --setup
# and re-granting Full Disk Access once.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="FSMetrics.app"
BUILT="build/$APP_NAME"
INSTALLED="/Applications/$APP_NAME"
SUPPORT_DIR="$HOME/Library/Application Support/FSMetrics"
SETTINGS="$SUPPORT_DIR/settings.json"
BUNDLED_CLI="$INSTALLED/Contents/Resources/fsmetrics"
SEED_RUNS=8
SEED_GAP=5
WITH_AGENT=0
RESET_SETTINGS=0

die() { echo "error: $*" >&2; exit 1; }

usage() {
    sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
}

installed_bundle_id() {
    plutil -extract CFBundleIdentifier raw "$INSTALLED/Contents/Info.plist" 2>/dev/null || echo "missing"
}

run_collect() {
    "$BUNDLED_CLI" collect --once >/dev/null
}

do_setup() {
    echo "==> Building and assembling the bundle (Scripts/bundle.sh)"
    Scripts/bundle.sh

    # Stop a running copy before replacing it under its feet.
    if pgrep -xq FSMetrics; then
        echo "==> Quitting the running FSMetrics"
        osascript -e 'quit app "FSMetrics"' >/dev/null 2>&1 || true
        sleep 1
        pkill -x FSMetrics 2>/dev/null || true
    fi

    if [[ -e "$INSTALLED" ]]; then
        local id
        id="$(installed_bundle_id)"
        [[ "$id" == "local.fsmetrics" ]] || die "$INSTALLED exists and is not FSMetrics; refusing to replace it"
        rm -rf "$INSTALLED"
    fi
    ditto "$BUILT" "$INSTALLED"
    xattr -dr com.apple.quarantine "$INSTALLED" 2>/dev/null || true
    echo "==> Installed $INSTALLED"

    mkdir -p "$SUPPORT_DIR"
    if [[ ! -f "$SETTINGS" || "$RESET_SETTINGS" -eq 1 ]]; then
        if [[ -f "$SETTINGS" ]]; then
            local backup="$SETTINGS.demo-backup.$(date +%Y%m%d%H%M%S)"
            cp "$SETTINGS" "$backup"
            echo "==> Existing settings backed up to $backup"
        fi
        local hostlabel
        hostlabel="$(scutil --get ComputerName 2>/dev/null || hostname -s)"
        cp config.example.json "$SETTINGS"
        HOSTLABEL="$hostlabel" perl -pi -e \
            's{("host_label"\s*:\s*)"[^"]*"}{$1 . qq("$ENV{HOSTLABEL}")}e' "$SETTINGS"
        echo "==> Installed default settings at $SETTINGS (host_label: $hostlabel)"
    else
        echo "==> Keeping existing settings at $SETTINGS"
        echo "    (use --reset-settings to restore config.example.json defaults)"
    fi

    if [[ "$WITH_AGENT" -eq 1 ]]; then
        echo "==> Installing the LaunchAgent"
        Scripts/install-agent.sh
    fi

    echo "==> Seeding chart history ($SEED_RUNS cycles, ${SEED_GAP}s apart)"
    local i
    for i in $(seq 1 "$SEED_RUNS"); do
        run_collect
        echo "    cycle $i/$SEED_RUNS"
        [[ "$i" -eq "$SEED_RUNS" ]] || sleep "$SEED_GAP"
    done

    echo "==> Opening Full Disk Access settings"
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles" || true

    cat <<'INSTRUCTIONS'

    Full Disk Access (one manual step — macOS has no scripted way to grant it):
      1. In the opened pane, press + and add /Applications/FSMetrics.app
         (press Cmd+Shift+G in the file dialog to type the path). Granting
         the app covers the UI.
      2. If you installed the LaunchAgent (--with-agent), also add
         /Applications/FSMetrics.app/Contents/Resources/fsmetrics
         (Cmd+Shift+G reaches inside the bundle).
      3. Toggle the switch ON for each entry.

    This single grant subsumes the per-folder prompts (Desktop, Documents,
    Downloads, Pictures), so no popups appear during the demo. Without it the
    affected collectors degrade gracefully: per-user usage and SMART rows are
    simply missing.

    Then confirm the grant took effect:
      Scripts/demo.sh --verify
INSTRUCTIONS

    do_verify
}

do_verify() {
    [[ -x "$BUNDLED_CLI" ]] || die "no bundled CLI at $BUNDLED_CLI; run --setup first"
    echo "==> Running one collection cycle"
    run_collect
    local count
    count="$(sqlite3 "$SUPPORT_DIR/metrics.sqlite" \
        "select count(*) from metric where kind='capacity.user_bytes';" 2>/dev/null || echo 0)"
    if [[ "$count" -gt 0 ]]; then
        echo "==> OK: $count per-user samples in the database — Full Disk Access is working"
    else
        echo "==> No per-user samples yet. If you have not granted Full Disk Access"
        echo "    yet, do so (see the --setup instructions), then re-run:"
        echo "    Scripts/demo.sh --verify"
    fi
}

do_launch() {
    [[ -d "$INSTALLED" ]] || die "$INSTALLED is not installed. Run: Scripts/demo.sh --setup"
    local exec_path="$INSTALLED/Contents/MacOS/FSMetrics"
    local newer=""
    newer="$(find Sources Package.swift Scripts/bundle.sh -newer "$exec_path" -print -quit 2>/dev/null || true)"
    if [[ -n "$newer" ]]; then
        echo "warning: source tree is newer than the installed app ('$newer' changed)." >&2
        echo "         run 'Scripts/demo.sh --setup' to update — this requires" >&2
        echo "         re-granting Full Disk Access afterwards." >&2
    fi
    open "$INSTALLED"
    echo "==> Launched $INSTALLED"
    echo "    Menu-bar icon (top right) → Open Dashboard."
}

MODE="launch"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --setup) MODE="setup" ;;
        --verify) MODE="verify" ;;
        --seed)
            [[ $# -ge 2 ]] || die "--seed requires a number"
            SEED_RUNS="$2"
            shift 2
            ;;
        --with-agent) WITH_AGENT=1 ;;
        --reset-settings) RESET_SETTINGS=1 ;;
        -h|--help) usage ;;
        *) die "unknown argument: $1 (see --help)" ;;
    esac
    shift
done

case "$MODE" in
    setup) do_setup ;;
    verify) do_verify ;;
    launch) do_launch ;;
esac
