#!/usr/bin/env bash
# Builds Notchka in Release configuration, and if a certificate is available, signs it with a Developer ID
# Application signature, packages it into a DMG with a branded background, and (optionally)
# notarizes the resulting image via notarytool.
#
# Personal signing identity and notarization credentials are never stored in the repository —
# they are passed via environment variables at run time. Without them, the script
# will build an ad-hoc DMG suitable for local testing, but not for public
# distribution (Gatekeeper will not allow such a build through without a warning).
#
# Environment variables:
#   CODE_SIGN_IDENTITY   Full code signing identity string
#                        (e.g. "Developer ID Application: Name (TEAMID)").
#                        Defaults to ad-hoc ("-").
#   DEVELOPMENT_TEAM     10-character Team ID. Required together with
#                        CODE_SIGN_IDENTITY, if it is not ad-hoc.
#   NOTARIZE             "1" — notarize the resulting DMG. Requires
#                        NOTARY_KEYCHAIN_PROFILE.
#   NOTARY_KEYCHAIN_PROFILE
#                        Name of a profile previously saved via
#                        `xcrun notarytool store-credentials`.
#
# Example of a full public release:
#   CODE_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
#   DEVELOPMENT_TEAM=TEAMID \
#   NOTARIZE=1 NOTARY_KEYCHAIN_PROFILE=notchka-notary \
#   ./scripts/build-dmg.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"
NOTARIZE="${NOTARIZE:-0}"
NOTARY_KEYCHAIN_PROFILE="${NOTARY_KEYCHAIN_PROFILE:-}"

if [[ "$NOTARIZE" == "1" && -z "$NOTARY_KEYCHAIN_PROFILE" ]]; then
  echo "error: NOTARIZE=1 requires NOTARY_KEYCHAIN_PROFILE" >&2
  exit 1
fi
if [[ "$CODE_SIGN_IDENTITY" != "-" && -z "$DEVELOPMENT_TEAM" ]]; then
  echo "error: CODE_SIGN_IDENTITY is set but DEVELOPMENT_TEAM is not" >&2
  exit 1
fi

VERSION="$(grep 'MARKETING_VERSION:' project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
BUILD_DIR="$REPO_ROOT/build"
DERIVED_DATA="$BUILD_DIR/DerivedData"
STAGING_DIR="$BUILD_DIR/dmg-staging"
DMG_TMP="$BUILD_DIR/Notchka-tmp.dmg"
DMG_FINAL="$BUILD_DIR/Notchka-$VERSION.dmg"
VOLUME_NAME="Notchka"

rm -rf "$STAGING_DIR" "$DMG_TMP" "$DMG_FINAL"
mkdir -p "$STAGING_DIR"

echo "==> Generating Xcode project"
xcodegen generate

echo "==> Building Release (identity: $CODE_SIGN_IDENTITY)"
xcodebuild \
  -project Notchka.xcodeproj \
  -scheme Notchka \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY" \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  clean build

APP_PATH="$DERIVED_DATA/Build/Products/Release/Notchka.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "error: build did not produce $APP_PATH" >&2
  exit 1
fi

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "==> Assembling DMG contents"
cp -R "$APP_PATH" "$STAGING_DIR/Notchka.app"
ln -s /Applications "$STAGING_DIR/Applications"
mkdir -p "$STAGING_DIR/.background"
cp "$REPO_ROOT/scripts/dmg-assets/dmg-background.png" "$STAGING_DIR/.background/background.png"

echo "==> Creating temporary image"
hdiutil create -volname "$VOLUME_NAME" -srcfolder "$STAGING_DIR" -ov -format UDRW -size 200m "$DMG_TMP"

MOUNT_DIR="$(hdiutil attach -readwrite -noverify -noautoopen "$DMG_TMP" | tail -1 | awk '{print $NF}')"
if [[ -z "$MOUNT_DIR" ]]; then
  echo "error: failed to mount temporary image" >&2
  exit 1
fi

echo "==> Configuring Finder window appearance ($MOUNT_DIR)"
# Icon positions here are synced with the badge and arrow coordinates in
# scripts/dmg-assets/dmg-background.png (see IconRenderer/main.swift,
# function dmgBackground) — the background draws the hint right under these points.
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOLUME_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {400, 100, 1060, 500}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set background picture of viewOptions to file ".background:background.png"
        set position of item "Notchka.app" of container window to {180, 175}
        set position of item "Applications" of container window to {480, 175}
        close
        open
        update without registering applications
        delay 1
    end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$MOUNT_DIR"

echo "==> Converting to a compressed read-only image"
hdiutil convert "$DMG_TMP" -format UDZO -imagekey zlib-level=9 -o "$DMG_FINAL"
rm -f "$DMG_TMP"
rm -rf "$STAGING_DIR"

if [[ "$NOTARIZE" == "1" ]]; then
  echo "==> Submitting for notarization (profile: $NOTARY_KEYCHAIN_PROFILE)"
  xcrun notarytool submit "$DMG_FINAL" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait
  echo "==> Stapling notarization ticket"
  xcrun stapler staple "$DMG_FINAL"
  xcrun stapler validate "$DMG_FINAL"
fi

echo "==> Done: $DMG_FINAL"
shasum -a 256 "$DMG_FINAL"
