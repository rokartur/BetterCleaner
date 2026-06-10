#!/bin/bash
# Build, sign (Developer ID), notarize, and staple BetterCleaner for distribution.
#
# One-time credential setup (stores an App Store Connect / Apple ID profile in the
# keychain so this script runs unattended):
#
#   xcrun notarytool store-credentials BetterCleanerNotary \
#       --apple-id "you@example.com" \
#       --team-id N529W98U62 \
#       --password "app-specific-password"   # appleid.apple.com → App-Specific Passwords
#
# Then:  ./scripts/notarize.sh
#
# Requires: the "Developer ID Application: Artur Rok (N529W98U62)" cert in the
# keychain (already present) and macOS hardened runtime (already enabled on Release).
set -euo pipefail

PROJECT="BetterCleaner.xcodeproj"
SCHEME="BetterCleaner"
PROFILE="${NOTARY_PROFILE:-BetterCleanerNotary}"   # override: NOTARY_PROFILE=... ./scripts/notarize.sh
DIST="dist"
DERIVED="$DIST/DerivedData"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p "$DIST"

# CFBundleVersion must strictly increase per release. Derive it from the git
# commit count so every release build gets a unique, monotonic build number —
# no manual bump, no hardcoded "1". MARKETING_VERSION (the user-facing version)
# is still edited by hand in the project.
BUILD_NUMBER="$(git rev-list --count HEAD)"
echo "▸ Building Release (Developer ID, hardened runtime, build $BUILD_NUMBER)…"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -destination 'platform=macOS' -derivedDataPath "$DERIVED" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" clean build

APP="$DERIVED/Build/Products/Release/BetterCleaner.app"
[ -d "$APP" ] || { echo "✗ build product not found at $APP"; exit 1; }

echo "▸ Verifying signature is Developer ID + hardened runtime…"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dvv "$APP" 2>&1 | grep -q "Authority=Developer ID Application" \
    || { echo "✗ not signed with Developer ID Application"; exit 1; }
codesign -dvv "$APP" 2>&1 | grep -q "flags=0x10000(runtime)" \
    || { echo "✗ hardened runtime not enabled"; exit 1; }

ZIP="$DIST/BetterCleaner.zip"
echo "▸ Zipping for notarization → $ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "▸ Submitting to Apple notary service (profile: $PROFILE)…"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "▸ Stapling the ticket to the app…"
xcrun stapler staple "$APP"

echo "▸ Gatekeeper assessment…"
spctl -a -vvv --type exec "$APP"

echo "▸ Re-zipping the stapled app for distribution → $ZIP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "✓ Done. Notarized + stapled: $ZIP"
