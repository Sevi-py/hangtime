#!/bin/zsh
# Builds a signed, notarized Headroom release and (with --publish) ships it to GitHub Releases and the Homebrew cask.
#
#   scripts/release.sh 1.2.0             build, sign (Developer ID), notarize and staple into dist/; publish nothing
#   scripts/release.sh 1.2.0 --publish   also: bump project.yml, tag v1.2.0, create the GitHub release, update Casks/headroom.rb
#
# One-time setup on the release Mac:
#   - Xcode signed in with an account on team 8XX544GLPH (Flarely e.U.), so Xcode can use the cloud-managed
#     "Developer ID Application" certificate.
#   - Notarization credentials in the Keychain:
#       xcrun notarytool store-credentials headroom-notary --apple-id <id> --team-id 8XX544GLPH --password <app-specific>
#   - gh authenticated with push access to the repo.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${1:-}
PUBLISH=${2:-}
TEAM=8XX544GLPH
PROFILE=${NOTARY_PROFILE:-headroom-notary}
REPO=Sevi-py/usage-widget

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: $0 <major.minor.patch> [--publish]"; exit 1; }
if [[ "$PUBLISH" == "--publish" ]]; then
  [[ -z "$(git status --porcelain)" ]] || { echo "Working tree is not clean. Commit first."; exit 1; }
  [[ "$(git branch --show-current)" == main ]] || { echo "Release from main."; exit 1; }
  git rev-parse "v$VERSION" >/dev/null 2>&1 && { echo "Tag v$VERSION already exists."; exit 1; }
fi

BUILD=$(date +%Y%m%d%H%M%S)
DIST=dist/$VERSION
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
rm -rf "$DIST"; mkdir -p "$DIST"

step() { print -P "%F{cyan}==> $1%f" }

step "Archiving $VERSION ($BUILD)"
xcodegen generate >/dev/null
xcodebuild -project Headroom.xcodeproj -scheme Headroom -configuration Release \
  -archivePath "$WORK/Headroom.xcarchive" -derivedDataPath build/release -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=$TEAM MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" archive \
  | grep -E "error:|ARCHIVE (SUCCEEDED|FAILED)" || true
[[ -d "$WORK/Headroom.xcarchive" ]] || { echo "Archive failed"; exit 1; }

step "Exporting with Developer ID"
cat > "$WORK/export.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
EOF
xcodebuild -exportArchive -archivePath "$WORK/Headroom.xcarchive" -exportOptionsPlist "$WORK/export.plist" \
  -exportPath "$WORK/export" -allowProvisioningUpdates 2>&1 | grep -E "error|EXPORT (SUCCEEDED|FAILED)" || true
APP="$WORK/export/Headroom.app"
[[ -d "$APP" ]] || { echo "Export failed"; exit 1; }
codesign --verify --deep --strict -R="anchor apple generic and certificate leaf[subject.OU] = \"$TEAM\"" "$APP"
[[ "$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString)" == "$VERSION" ]]

step "Notarizing the app"
ditto -c -k --keepParent "$APP" "$WORK/notarize.zip"
xcrun notarytool submit "$WORK/notarize.zip" --keychain-profile "$PROFILE" --wait | tail -2
xcrun stapler staple -q "$APP"
spctl --assess --type execute "$APP"

ZIP="$DIST/Headroom-$VERSION.zip"
DMG="$DIST/Headroom-$VERSION.dmg"
step "Packaging"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
mkdir "$WORK/dmg"
ditto "$APP" "$WORK/dmg/Headroom.app"
ln -s /Applications "$WORK/dmg/Applications"
hdiutil create -volname "Headroom $VERSION" -srcfolder "$WORK/dmg" -ov -format UDZO -quiet "$DMG"

step "Notarizing the disk image"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait | tail -2
xcrun stapler staple -q "$DMG"

SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')
echo "$SHA  Headroom-$VERSION.zip" > "$DIST/SHA256SUMS"
shasum -a 256 "$DMG" | sed "s|$DIST/||" >> "$DIST/SHA256SUMS"
step "Built $DIST"
cat "$DIST/SHA256SUMS"

[[ "$PUBLISH" == "--publish" ]] || { echo "Dry run. Re-run with --publish to ship it."; exit 0; }

step "Bumping version and cask"
sed -i '' -E "s/MARKETING_VERSION: \"[^\"]+\"/MARKETING_VERSION: \"$VERSION\"/" project.yml
sed -i '' -E "s/^  version \".*\"/  version \"$VERSION\"/; s/^  sha256 \".*\"/  sha256 \"$SHA\"/" Casks/headroom.rb
xcodegen generate >/dev/null
git add project.yml Headroom.xcodeproj Casks/headroom.rb
git commit -q -m "Release $VERSION"
git tag -a "v$VERSION" -m "Headroom $VERSION"

step "Creating the GitHub release"
# Push the release commit and tag first so the release points at them.
git push -q origin main "v$VERSION"
PREV=$(git describe --tags --abbrev=0 "v$VERSION^" 2>/dev/null || true)
gh release create "v$VERSION" "$ZIP" "$DMG" "$DIST/SHA256SUMS" --repo "$REPO" --title "Headroom $VERSION" \
  --generate-notes ${PREV:+--notes-start-tag "$PREV"} --verify-tag

step "Released Headroom $VERSION"
echo "  https://github.com/$REPO/releases/tag/v$VERSION"
echo "  brew upgrade --cask headroom   (users on the tap)"
