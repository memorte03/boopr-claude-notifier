#!/usr/bin/env bash
# Builds a self-contained, sendable distribution of Beepaboop:
#   dist/Beepaboop-<version>.zip
#
# The ZIP contains a prebuilt universal .app (no Swift toolchain needed on the
# recipient's Mac), the hook scripts, and a double-clickable installer that
# wires everything up. Send that ZIP to a friend.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Beepaboop"
DISPLAY_NAME="Beepaboop"
BUNDLE_ID="com.memorte03.beepaboop"
cd "$REPO_ROOT"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist 2>/dev/null || echo 0.1.0)"
DIST="${REPO_ROOT}/dist"
STAGE="${DIST}/${DISPLAY_NAME}"
APP="${STAGE}/${DISPLAY_NAME}.app"

rm -rf "$DIST"
mkdir -p "$STAGE/support"
"${REPO_ROOT}/scripts/build-app.sh" "$APP"

echo "→ staging support files (hooks + signing helpers)"
mkdir -p "${STAGE}/support/hooks"
cp "${REPO_ROOT}/hooks/"*.sh "${STAGE}/support/hooks/"
cp "${REPO_ROOT}/scripts/lib-sign.sh" "${REPO_ROOT}/scripts/make-signing-cert.sh" "${STAGE}/support/"

echo "→ writing Install.command"
cat > "${STAGE}/Install.command" <<'INSTALLER'
#!/bin/bash
# Installs Beepaboop: copies the app to /Applications, wires the Claude
# Code hooks, and launches it. Safe to re-run.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPPORT="$HERE/support"
APP_SRC="$HERE/Beepaboop.app"
APP_DST="/Applications/Beepaboop.app"
BUNDLE_ID="com.memorte03.beepaboop"
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/beepaboop"
HOOKS_DIR="$CONFIG/hooks"
SETTINGS="$HOME/.claude/settings.json"
MATCHER="${BEEPABOOP_PRETOOL_MATCHER:-Bash|Write|Edit|MultiEdit|NotebookEdit}"

echo "Installing Beepaboop…"

if ! command -v jq >/dev/null 2>&1; then
    echo
    echo "  jq is required and isn't installed. Install it, then re-run this:"
    echo "    brew install jq        (get Homebrew at https://brew.sh)"
    echo
    read -r -p "Press return to close." _ || true
    exit 1
fi

echo "→ copying app to /Applications"
pkill -x Beepaboop 2>/dev/null || true
sleep 0.4
rm -rf "$APP_DST"
# ditto overwrites cleanly — unlike `cp -R`, it won't nest the bundle inside an
# existing target if the rm above raced with Launch Services reopening the app.
ditto "$APP_SRC" "$APP_DST"
xattr -dr com.apple.quarantine "$APP_DST" 2>/dev/null || true

# Sign with a stable per-machine certificate so macOS keeps the Accessibility /
# Automation permissions across relaunches; fall back to ad-hoc if that fails.
# shellcheck source=/dev/null
source "$SUPPORT/lib-sign.sh"
if [[ "$(cn_sign_identity)" == "-" ]]; then
    echo "→ creating a local signing certificate (keeps permissions from resetting)"
    echo "  macOS may ask for your login password — that's expected."
    bash "$SUPPORT/make-signing-cert.sh" || echo "  (continuing with ad-hoc signing)"
fi
echo "→ signing the app"
cn_sign_bundle "$APP_DST" "$BUNDLE_ID"

echo "→ installing hooks to $HOOKS_DIR"
mkdir -p "$HOOKS_DIR"
cp "$SUPPORT/hooks/"*.sh "$HOOKS_DIR/"
chmod +x "$HOOKS_DIR/notify.sh" "$HOOKS_DIR/permission.sh"

echo "→ wiring $SETTINGS"
mkdir -p "$(dirname "$SETTINGS")"
[[ -f "$SETTINGS" ]] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak"
if jq --arg notify "$HOOKS_DIR/notify.sh" \
   --arg permission "$HOOKS_DIR/permission.sh" \
   --arg matcher "$MATCHER" '
    def drop_ours(list):
        (list // []) | map(select(((.hooks // []) | any(.command | test("beepaboop"))) | not));
    .hooks.Stop         = drop_ours(.hooks.Stop)         + [{matcher:"",        hooks:[{type:"command",command:$notify}]}]
  | .hooks.Notification = drop_ours(.hooks.Notification) + [{matcher:"",        hooks:[{type:"command",command:$notify}]}]
  | .hooks.PreToolUse   = drop_ours(.hooks.PreToolUse)   + [{matcher:$matcher,  hooks:[{type:"command",command:$permission}]}]
' "$SETTINGS" > "$SETTINGS.tmp"; then
    mv "$SETTINGS.tmp" "$SETTINGS"
else
    rm -f "$SETTINGS.tmp"
    echo "  ⚠ $SETTINGS isn't valid JSON — left it unchanged (backup at $SETTINGS.bak)."
fi

echo "→ launching"
open "$APP_DST"

cat <<EOF

Done! Beepaboop is in your menu bar (the bell icon).

One-time setup:
  - Grant Accessibility and Automation when prompted (or from the menu
    bar bell → Permissions). They're needed for "Jump to session".
  - Menu bar bell → "Launch at Login" to start it automatically.

Notifications appear when Claude Code finishes, waits, or asks permission.
EOF
read -r -p "Press return to close." _ || true
INSTALLER
chmod +x "${STAGE}/Install.command"

echo "→ writing README.txt"
cat > "${STAGE}/README.txt" <<EOF
Beepaboop — native macOS overlay for Claude Code
======================================================

A menu-bar app that pops a notification when Claude Code finishes, needs
input, or asks for permission — on whatever Space you're currently on —
with Approve/Deny and a one-click jump to the right terminal session.

REQUIREMENTS
  - macOS 14 (Sonoma) or newer
  - jq        ->  brew install jq        (Homebrew: https://brew.sh)
  - Claude Code
  - Best experience: tmux + Ghostty 1.3+ (for cross-Space jump-to-session)

INSTALL
  1. Install jq if you don't have it:   brew install jq
  2. Open Terminal, type "bash " (with a space), then DRAG the file
     "Install.command" (next to this README) into the Terminal window
     and press Return.
       - Running it this way avoids the macOS "unidentified developer"
         warning. (Double-clicking works too, but you'll have to
         right-click -> Open, or approve it in System Settings ->
         Privacy & Security.)
  3. Follow the prompts. Grant Accessibility + Automation when asked.

This app isn't from the App Store and isn't notarized by Apple, so macOS
is cautious about it — that's why the installer clears the quarantine flag
and signs it locally on your machine.

UNINSTALL
  Delete /Applications/Beepaboop.app and the folder
  ~/.config/beepaboop, and remove the "beepaboop" hook entries
  from ~/.claude/settings.json (a backup was saved as settings.json.bak).

Version ${VERSION}
EOF

echo "→ zipping"
ZIP="${DIST}/Beepaboop-${VERSION}.zip"
( cd "$DIST" && ditto -c -k --sequesterRsrc --keepParent "${DISPLAY_NAME}" "$ZIP" )

echo
echo "✓ built: $ZIP"
echo "  architectures: $(lipo -archs "${APP}/Contents/MacOS/${APP_NAME}")"
du -h "$ZIP" | awk '{print "  size: " $1}'
echo "  send that .zip to your friend; they follow the steps in README.txt."
