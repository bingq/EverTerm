#!/bin/bash
# Build a signed, notarized EverTerm.app and a zip for a GitHub release (macOS only).
#
# One-time setup:
#   1. A "Developer ID Application" certificate in your login keychain
#      (Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application).
#   2. Notary credentials stored in the keychain:
#        xcrun notarytool store-credentials everterm-notary \
#          --apple-id <your Apple ID> --team-id <TEAM_ID> --password <app-specific password>
#      (app-specific password: account.apple.com > Sign-In and Security > App-Specific Passwords)
#
# Usage:  scripts/release.sh 0.9 [build]
set -euo pipefail
VERSION="${1:?usage: scripts/release.sh <version> [build]}"
BUILD="${2:-1}"
BUNDLE_ID="${EVERTERM_BUNDLE_ID:-io.github.bingq.EverTerm}"
PROFILE="${EVERTERM_NOTARY_PROFILE:-everterm-notary}"
IDENTITY="${EVERTERM_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')}"
[ -n "$IDENTITY" ] || { echo "No 'Developer ID Application' certificate found in the keychain."; exit 1; }

cd "$(dirname "$0")/.."
OUT=dist; APP="$OUT/EverTerm.app"
rm -rf "$OUT"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "== build (release, Apple silicon + Intel)"
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

echo "== bundle"
cp "$BIN/EverTerm" "$APP/Contents/MacOS/EverTerm"
# SwiftPM resource bundle: only used under `swift run` (see AppDelegate); copied for completeness.
for b in "$BIN"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done
iconutil -c icns Icon/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
sed -e "s/__BUNDLE_ID__/$BUNDLE_ID/" -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" \
    scripts/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"

echo "== sign ($IDENTITY)"
find "$APP/Contents/Resources" -name '*.bundle' -maxdepth 1 -exec codesign --force --timestamp --sign "$IDENTITY" {} \;
codesign --force --timestamp --options runtime --entitlements scripts/entitlements.plist --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "== notarize (uploads to Apple, waits for the result)"
ditto -c -k --keepParent "$APP" "$OUT/EverTerm-notarize.zip"
xcrun notarytool submit "$OUT/EverTerm-notarize.zip" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose=2 "$APP"

echo "== package"
ditto -c -k --keepParent "$APP" "$OUT/EverTerm-$VERSION.zip"
rm "$OUT/EverTerm-notarize.zip"
shasum -a 256 "$OUT/EverTerm-$VERSION.zip"
echo "Done: $OUT/EverTerm-$VERSION.zip (notarized, stapled)"
