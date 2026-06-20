#!/usr/bin/env bash
# Builds Beepaboop, packages it as a proper .app bundle, installs it into
# /Applications, copies the hook scripts to a stable location, and wires them
# into ~/.claude/settings.json. Idempotent: safe to re-run after updates.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Beepaboop"
DISPLAY_NAME="Beepaboop"
BUNDLE_ID="com.memorte03.beepaboop"
INSTALL_DIR="/Applications"
APP_BUNDLE="${INSTALL_DIR}/${DISPLAY_NAME}.app"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/beepaboop"
HOOKS_DIR="${CONFIG_DIR}/hooks"
CLAUDE_SETTINGS="${HOME}/.claude/settings.json"
# Tools that surface an overlay Approve/Deny prompt. Adjust to taste, re-run.
PRETOOL_MATCHER="${BEEPABOOP_PRETOOL_MATCHER:-Bash|Write|Edit|MultiEdit|NotebookEdit}"

# ── prerequisites ───────────────────────────────────────────────────────────
if ! command -v jq >/dev/null 2>&1; then
    echo "error: jq is required (hooks are built with it): brew install jq" >&2
    exit 1
fi
if ! command -v swift >/dev/null 2>&1; then
    echo "error: swift toolchain not found — install Xcode or Command Line Tools" >&2
    exit 1
fi

cd "$REPO_ROOT"

echo "→ building release binary"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/${APP_NAME}"
if [[ ! -x "$BIN_PATH" ]]; then
    echo "build did not produce ${BIN_PATH}" >&2
    exit 1
fi

echo "→ stopping any running instance"
# -x matches the exact process name (covers both the installed and the in-place
# dev binary), unlike -f which scans the whole command line and could match an
# unrelated process (an editor, a tail) whose args end in that path.
pkill -x "${APP_NAME}" 2>/dev/null || true
sleep 0.3

echo "→ assembling bundle"
STAGING="$(mktemp -d)/${DISPLAY_NAME}.app"
mkdir -p "${STAGING}/Contents/MacOS" "${STAGING}/Contents/Resources"
cp "$BIN_PATH" "${STAGING}/Contents/MacOS/${APP_NAME}"
cp "${REPO_ROOT}/Resources/Info.plist" "${STAGING}/Contents/Info.plist"
if [[ -f "${REPO_ROOT}/Resources/AppIcon.icns" ]]; then
    cp "${REPO_ROOT}/Resources/AppIcon.icns" "${STAGING}/Contents/Resources/AppIcon.icns"
fi
# Bundle the hooks so the app can self-install them on first launch.
mkdir -p "${STAGING}/Contents/Resources/hooks"
cp "${REPO_ROOT}/hooks/"*.sh "${STAGING}/Contents/Resources/hooks/"
chmod +x "${STAGING}/Contents/MacOS/${APP_NAME}"

echo "→ installing to ${APP_BUNDLE}"
rm -rf "$APP_BUNDLE"
mv "$STAGING" "$APP_BUNDLE"
# Clear any quarantine attr so Gatekeeper doesn't flag it on first launch.
xattr -dr com.apple.quarantine "$APP_BUNDLE" 2>/dev/null || true

echo "→ signing (stable cert if available, else ad-hoc)"
# shellcheck source=lib-sign.sh
source "${REPO_ROOT}/scripts/lib-sign.sh"
cn_sign_bundle "$APP_BUNDLE" "$BUNDLE_ID"

# ── hooks: copy to a stable path that survives moving/deleting the repo ─────
echo "→ installing hooks to ${HOOKS_DIR}"
mkdir -p "$HOOKS_DIR"
cp "${REPO_ROOT}/hooks/beepaboop-common.sh" \
   "${REPO_ROOT}/hooks/notify.sh" \
   "${REPO_ROOT}/hooks/permission.sh" "$HOOKS_DIR/"
chmod +x "${HOOKS_DIR}/notify.sh" "${HOOKS_DIR}/permission.sh"

# ── wire hooks into ~/.claude/settings.json ─────────────────────────────────
# Strategy: drop any existing beepaboop entries (old paths included),
# then append fresh ones — re-running always converges on the current config.
echo "→ updating ${CLAUDE_SETTINGS}"
mkdir -p "$(dirname "$CLAUDE_SETTINGS")"
[[ -f "$CLAUDE_SETTINGS" ]] || echo '{}' > "$CLAUDE_SETTINGS"
cp "$CLAUDE_SETTINGS" "${CLAUDE_SETTINGS}.bak"

if jq --arg notify "${HOOKS_DIR}/notify.sh" \
   --arg permission "${HOOKS_DIR}/permission.sh" \
   --arg matcher "$PRETOOL_MATCHER" '
    def drop_ours(list):
        (list // []) | map(select(
            ((.hooks // []) | any(.command | test("beepaboop"))) | not
        ));
    .hooks.Stop         = drop_ours(.hooks.Stop)
                          + [{matcher: "", hooks: [{type: "command", command: $notify}]}]
  | .hooks.Notification = drop_ours(.hooks.Notification)
                          + [{matcher: "", hooks: [{type: "command", command: $notify}]}]
  | .hooks.PreToolUse   = drop_ours(.hooks.PreToolUse)
                          + [{matcher: $matcher, hooks: [{type: "command", command: $permission}]}]
' "$CLAUDE_SETTINGS" > "${CLAUDE_SETTINGS}.tmp"; then
    mv "${CLAUDE_SETTINGS}.tmp" "$CLAUDE_SETTINGS"
else
    rm -f "${CLAUDE_SETTINGS}.tmp"
    echo "   ⚠ ${CLAUDE_SETTINGS} isn't valid JSON — left it unchanged (backup at ${CLAUDE_SETTINGS}.bak)." >&2
    echo "   Fix the JSON and re-run, or add the hooks manually." >&2
fi

echo "→ launching"
open "$APP_BUNDLE"

cat <<EOF

installed:
  app:    ${APP_BUNDLE}
  hooks:  ${HOOKS_DIR}
  config: ${CLAUDE_SETTINGS} (backup at ${CLAUDE_SETTINGS}.bak)

next steps:
  - grant Accessibility when prompted (and Automation on first jump)
  - menu bar → Beepaboop → "Launch at Login" to enable auto-start
  - permission prompts cover: ${PRETOOL_MATCHER}
    (re-run with BEEPABOOP_PRETOOL_MATCHER="..." to change)

uninstall any time with: scripts/uninstall.sh
EOF
