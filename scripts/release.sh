#!/bin/bash
# Build EverTerm.app and a zip for a GitHub release (macOS only). No Apple account needed.
#
#   scripts/release.sh 0.9 [build]
#
# By default the app is ad-hoc signed: it runs on the Mac that built it with no warning.
# Someone who downloads the zip has to allow it once (right-click > Open, or
# System Settings > Privacy & Security > Open Anyway).
#
# Optional, only if you ever get an Apple Developer ID certificate: set
#   EVERTERM_SIGN_IDENTITY="Developer ID Application: ..."  and  EVERTERM_NOTARIZE=1
# (with notary credentials stored as profile "everterm-notary") to sign and notarize.
#
# #23 step 1, sandboxed test build:  EVERTERM_SANDBOX=1 scripts/release.sh 0.9
# Builds dist-sandbox/EverTerm.app (bundle ID + ".sandboxtest", so its container and settings
# are separate), ad-hoc signed with the App Sandbox, with a copy of ssh inside the bundle and
# the probe script. Run it with: open dist-sandbox/EverTerm.app  (do not copy it to /Applications).
# EVERTERM_SANDBOX_TTY=1 adds a test-only sandbox exception that allows terminal control calls
# (ioctl) on any file; EVERTERM_SANDBOX_TTY=narrow allows them only on the pty devices.
set -euo pipefail
VERSION="${1:?usage: scripts/release.sh <version> [build]}"
BUILD="${2:-1}"
BUNDLE_ID="${EVERTERM_BUNDLE_ID:-io.github.bingq.EverTerm}"
IDENTITY="${EVERTERM_SIGN_IDENTITY:--}"
NOTARIZE="${EVERTERM_NOTARIZE:-0}"
PROFILE="${EVERTERM_NOTARY_PROFILE:-everterm-notary}"
SANDBOX="${EVERTERM_SANDBOX:-0}"
[ "$SANDBOX" = "1" ] && BUNDLE_ID="$BUNDLE_ID.sandboxtest"

cd "$(dirname "$0")/.."
OUT=dist; [ "$SANDBOX" = "1" ] && OUT=dist-sandbox
APP="$OUT/EverTerm.app"
rm -rf "$OUT"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "== build (release, Apple silicon + Intel)"
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

echo "== bundle"
cp "$BIN/EverTerm" "$APP/Contents/MacOS/EverTerm"
# The SwiftPM resource bundle (Dock icon PNG) is only used under `swift run` (see AppDelegate),
# so it is left out: the app uses AppIcon.icns from its Info.plist.
iconutil -c icns Icon/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
sed -e "s/__BUNDLE_ID__/$BUNDLE_ID/" -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" \
    scripts/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"
if [ "$SANDBOX" = "1" ]; then
    mkdir -p "$APP/Contents/Helpers"
    cp /usr/bin/ssh "$APP/Contents/Helpers/ssh"
    cp scripts/sandbox-probe.sh "$APP/Contents/Resources/sandbox-probe.sh"
    chmod +x "$APP/Contents/Resources/sandbox-probe.sh"
fi

echo "== sign (${IDENTITY/#-/ad-hoc})"
if [ "$SANDBOX" = "1" ]; then
    codesign --force --sign - --entitlements scripts/sandbox-helper.entitlements "$APP/Contents/Helpers/ssh"
    ENT=scripts/sandbox.entitlements
    # 1 = any file (wide test); narrow = only the pty devices, the rule to ask App Review for.
    TTY="${EVERTERM_SANDBOX_TTY:-0}"
    RULE=""
    [ "$TTY" = "1" ] && RULE='(allow file-ioctl)'
    [ "$TTY" = "narrow" ] && RULE='(allow file-ioctl (literal "/dev/ptmx") (regex #"^/dev/ttys[0-9]+$"))'
    if [ -n "$RULE" ]; then
        ENT="$OUT/sandbox-tty.entitlements"
        python3 - "$RULE" scripts/sandbox.entitlements "$ENT" <<'PY'
import sys
rule, src, dst = sys.argv[1:]
from xml.sax.saxutils import escape
s = open(src).read().replace("</dict>",
    "    <key>com.apple.security.temporary-exception.sbpl</key>\n"
    "    <array><string>" + escape(rule) + "</string></array>\n</dict>")
open(dst, "w").write(s)
PY
        plutil -lint "$ENT"
        echo "test exception ($TTY): $RULE"
    fi
    codesign --force --sign - --entitlements "$ENT" "$APP"
    codesign -d --entitlements - "$APP" 2>/dev/null | grep -q app-sandbox && echo "sandbox: on"
elif [ "$IDENTITY" = "-" ]; then
    codesign --force --sign - "$APP"
else
    codesign --force --timestamp --options runtime --entitlements scripts/entitlements.plist --sign "$IDENTITY" "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"

if [ "$NOTARIZE" = "1" ]; then
    echo "== notarize (uploads to Apple, waits for the result)"
    ditto -c -k --keepParent "$APP" "$OUT/EverTerm-notarize.zip"
    xcrun notarytool submit "$OUT/EverTerm-notarize.zip" --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$APP"
    rm "$OUT/EverTerm-notarize.zip"
fi

echo "== package"
ditto -c -k --keepParent "$APP" "$OUT/EverTerm-$VERSION.zip"
shasum -a 256 "$OUT/EverTerm-$VERSION.zip"
echo "Done: $APP and $OUT/EverTerm-$VERSION.zip"
echo "Install for yourself: cp -R $APP /Applications/"
