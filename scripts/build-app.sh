#!/usr/bin/env bash
# Builds the universal, signed Beepaboop.app into the path given as $1.
# Shared by package.sh (ZIP) and make-dmg.sh (DMG). The hook scripts are bundled
# into Contents/Resources/hooks so the app can self-install them on first launch.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Beepaboop"
BUNDLE_ID="com.memorte03.beepaboop"
OUT="${1:?usage: build-app.sh <output-path.app>}"
cd "$REPO_ROOT"

for tool in swift lipo codesign; do
    command -v "$tool" >/dev/null 2>&1 || { echo "error: '$tool' not found (install Xcode / Command Line Tools)" >&2; exit 1; }
done

echo "→ building universal release (arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64 >/dev/null
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/${APP_NAME}"
# `lipo -archs` order isn't guaranteed (arm64 hosts print "arm64 x86_64"), so
# check each arch independently rather than matching a fixed string.
archs="$(lipo -archs "$BIN")"
for a in arm64 x86_64; do
    grep -qw "$a" <<<"$archs" || { echo "binary missing $a arch (got: $archs)" >&2; exit 1; }
done

echo "→ assembling $OUT"
rm -rf "$OUT"
mkdir -p "${OUT}/Contents/MacOS" "${OUT}/Contents/Resources/hooks"
cp "$BIN" "${OUT}/Contents/MacOS/${APP_NAME}"
cp "${REPO_ROOT}/Resources/Info.plist" "${OUT}/Contents/Info.plist"
[[ -f "${REPO_ROOT}/Resources/AppIcon.icns" ]] && cp "${REPO_ROOT}/Resources/AppIcon.icns" "${OUT}/Contents/Resources/"
compgen -G "${REPO_ROOT}/hooks/*.sh" >/dev/null || { echo "no hook scripts in ${REPO_ROOT}/hooks" >&2; exit 1; }
cp "${REPO_ROOT}/hooks/"*.sh "${OUT}/Contents/Resources/hooks/"
chmod +x "${OUT}/Contents/MacOS/${APP_NAME}"

echo "→ ad-hoc signing"
codesign --force --sign - --identifier "$BUNDLE_ID" "$OUT" >/dev/null
echo "   built $(lipo -archs "${OUT}/Contents/MacOS/${APP_NAME}")"
