#!/usr/bin/env bash
#
# Install ~/Library/LaunchAgents/local.fsmetrics.plist so the collector starts
# at login and is kept alive. Unsigned-safe fallback for SMAppService; see
# docs/SWIFT_TRANSLATION_PLAN.md section 14.
set -euo pipefail

LABEL="local.fsmetrics"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
CLI_NAME="fsmetrics"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Prefer a bundled CLI, then the SwiftPM release build directory. The bundled
# CLI lives in Contents/Resources because Contents/MacOS/fsmetrics would
# collide with Contents/MacOS/FSMetrics on a case-insensitive filesystem.
CLI=""
for candidate in \
    "/Applications/FSMetrics.app/Contents/Resources/$CLI_NAME" \
    "$ROOT/build/FSMetrics.app/Contents/Resources/$CLI_NAME"; do
    if [[ -x "$candidate" ]]; then
        CLI="$candidate"
        break
    fi
done
if [[ -z "$CLI" ]]; then
    BIN="$(swift build -c release --show-bin-path)"
    CLI="$BIN/$CLI_NAME"
fi
if [[ ! -x "$CLI" ]]; then
    echo "error: no $CLI_NAME binary at '$CLI'." >&2
    echo "       Run Scripts/bundle.sh (or 'swift build -c release') first." >&2
    exit 1
fi

UID_NUM="$(id -u)"
if ! launchctl print "gui/$UID_NUM" >/dev/null 2>&1; then
    echo "error: no GUI session for uid $UID_NUM." >&2
    echo "       'launchctl bootstrap gui/$UID_NUM' needs a logged-in desktop" >&2
    echo "       session; run this from Terminal on the Mac, not over SSH." >&2
    exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>$CLI</string>
    <string>collect</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>/usr/sbin:/usr/bin:/bin:/usr/local/bin</string>
  </dict>
</dict></plist>
PLIST
plutil -lint "$PLIST"

launchctl bootout "gui/$UID_NUM" "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$UID_NUM" "$PLIST"

echo "==> Installed and loaded $PLIST"
echo "    Collector: $CLI collect"
echo "    Uninstall with:"
echo "      launchctl bootout gui/$UID_NUM $PLIST"
