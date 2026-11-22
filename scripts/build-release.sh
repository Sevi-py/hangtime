#!/bin/zsh
# Builds a universal (Apple silicon + Intel), Developer ID signed, notarized and stapled Hangtime into dist/<version>/:
#   Hangtime-<version>.zip  (used by the Homebrew cask and the in-app updater)
#   Hangtime-<version>.dmg  (for people downloading by hand)
#   SHA256SUMS
#
#   scripts/build-release.sh 1.2.0
#
# Signing, either:
#   - A "Developer ID Application" certificate with its private key in the Keychain (CI imports it from the
#     DEVELOPER_ID_P12 secret). Used when present; it also signs the DMG.
#   - Otherwise Xcode's cloud-managed Developer ID certificate, which needs Xcode signed in with an account that
#     may use it. The DMG is then unsigned (but notarized and stapled; the app inside is signed).
# Notarization, either:
#   - App Store Connect API key in ASC_KEY_PATH, ASC_KEY_ID, ASC_ISSUER_ID (CI), or
#   - a notarytool Keychain profile (NOTARY_PROFILE, default hangtime-notary).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${1:-}
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: $0 <major.minor.patch>"; exit 1; }
TEAM=8XX544GLPH
BUILD=${BUILD_NUMBER:-$(date +%Y%m%d%H%M%S)}
DIST=dist/$VERSION
DERIVED=${DERIVED_DATA:-build/release}
WORK=$(mktemp -d)
# On exit, unregister and delete every app copy this build made (the export in $WORK and the copy the archive
# leaves in DerivedData), so Spotlight and Launch Services only know /Applications/Hangtime.app.
cleanup() {
  local ls=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  for app in "$WORK"/**/Hangtime.app(N/) "$DERIVED"/Build/Intermediates.noindex/ArchiveIntermediates/**/Hangtime.app(N/); do
    "$ls" -u "$app" >/dev/null 2>&1 || true
    rm -rf "$app"
  done
  rm -rf "$WORK"
}
trap cleanup EXIT
rm -rf "$DIST"; mkdir -p "$DIST"

step() { print -P "%F{cyan}==> $1%f" }

AUTH=()
NOTARY=(--keychain-profile "${NOTARY_PROFILE:-hangtime-notary}")
if [[ -n "${ASC_KEY_PATH:-}" ]]; then
  AUTH=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
  NOTARY=(--key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
fi

# A local Developer ID identity beats cloud signing: no Xcode account needed and the DMG gets signed too.
IDENTITY=$(security find-identity -v -p codesigning | grep -o "\"Developer ID Application: [^\"]*($TEAM)\"" | head -1 | tr -d '"' || true)
if [[ -n "$IDENTITY" ]]; then
  SIGNING="<key>signingStyle</key><string>manual</string><key>signingCertificate</key><string>Developer ID Application</string>"
  echo "Signing with $IDENTITY"
else
  SIGNING="<key>signingStyle</key><string>automatic</string>"
  echo "Signing with the cloud-managed Developer ID certificate"
fi

notarize() {
  local out
  out=$(xcrun notarytool submit "$1" "${NOTARY[@]}" --wait --output-format json)
  local id=$(print -r -- "$out" | plutil -extract id raw - 2>/dev/null || true)
  if ! print -r -- "$out" | grep -q '"status":"Accepted"'; then
    echo "Notarization failed: $out"
    [[ -n "$id" ]] && xcrun notarytool log "$id" "${NOTARY[@]}" || true
    exit 1
  fi
  echo "  notarized ($id)"
}

step "Archiving Hangtime $VERSION ($BUILD), universal"
command -v xcodegen >/dev/null && xcodegen generate >/dev/null
# The archive is signed ad hoc; the Developer ID export below re-signs everything. That way no development
# certificate is needed (CI has none). Compilation caching makes rebuilds fast when its cache is restored.
xcodebuild -project Hangtime.xcodeproj -scheme Hangtime -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$WORK/Hangtime.xcarchive" -derivedDataPath "$DERIVED" \
  DEVELOPMENT_TEAM=$TEAM CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  COMPILATION_CACHE_ENABLE_CACHING=YES MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" archive \
  | grep -E "error:|ARCHIVE (SUCCEEDED|FAILED)" || true
[[ -d "$WORK/Hangtime.xcarchive" ]] || { echo "Archive failed"; exit 1; }

step "Exporting with Developer ID"
cat > "$WORK/export.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM</string>
  $SIGNING
</dict></plist>
EOF
xcodebuild -exportArchive -archivePath "$WORK/Hangtime.xcarchive" -exportOptionsPlist "$WORK/export.plist" \
  -exportPath "$WORK/export" -allowProvisioningUpdates "${AUTH[@]}" 2>&1 | grep -E "error|EXPORT (SUCCEEDED|FAILED)" || true
APP="$WORK/export/Hangtime.app"
[[ -d "$APP" ]] || { echo "Export failed"; exit 1; }

# Sanity checks: right team, right version, both architectures in every binary.
codesign --verify --deep --strict -R="anchor apple generic and certificate leaf[subject.OU] = \"$TEAM\"" "$APP"
[[ "$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString)" == "$VERSION" ]] \
  || { echo "Version mismatch"; exit 1; }
for bin in "$APP/Contents/MacOS/Hangtime" "$APP"/Contents/PlugIns/*.appex/Contents/MacOS/*; do
  archs=$(lipo -archs "$bin")
  [[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || { echo "$bin is not universal ($archs)"; exit 1; }
done
echo "  universal: $(lipo -archs "$APP/Contents/MacOS/Hangtime")"

step "Notarizing the app"
ditto -c -k --keepParent "$APP" "$WORK/notarize.zip"
notarize "$WORK/notarize.zip"
xcrun stapler staple -q "$APP"
spctl --assess --type execute "$APP"

ZIP="$DIST/Hangtime-$VERSION.zip"
DMG="$DIST/Hangtime-$VERSION.dmg"
step "Packaging"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
mkdir "$WORK/dmg"
ditto "$APP" "$WORK/dmg/Hangtime.app"
ln -s /Applications "$WORK/dmg/Applications"
hdiutil create -volname "Hangtime $VERSION" -srcfolder "$WORK/dmg" -ov -format UDZO -quiet "$DMG"
if [[ -n "$IDENTITY" ]]; then codesign --sign "$IDENTITY" --timestamp "$DMG"; fi

step "Notarizing the disk image"
notarize "$DMG"
xcrun stapler staple -q "$DMG"

(cd "$DIST" && shasum -a 256 "Hangtime-$VERSION.zip" "Hangtime-$VERSION.dmg" > SHA256SUMS)
step "Built $DIST"
cat "$DIST/SHA256SUMS"
