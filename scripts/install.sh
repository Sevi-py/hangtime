#!/bin/zsh
# Builds Headroom (Release), replaces /Applications/Headroom.app and makes running widgets pick up the new build.
set -euo pipefail
cd "$(dirname "$0")/.."

# A fresh build number per install, so WidgetKit/chronod treat it as a new extension version.
BUILD=$(date +%Y%m%d%H%M%S)

xcodegen generate >/dev/null
xcodebuild -project Headroom.xcodeproj -scheme Headroom -configuration Release -derivedDataPath build \
  -allowProvisioningUpdates CURRENT_PROJECT_VERSION="$BUILD" build | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
APP=build/Build/Products/Release/Headroom.app
[[ -d "$APP" ]] || { echo "Build failed"; exit 1; }

# Quit the app and the old widget extension process.
pkill -x Headroom 2>/dev/null || true
pkill -f "HeadroomWidgets.appex" 2>/dev/null || true
sleep 1

rm -rf /Applications/Headroom.app
cp -R "$APP" /Applications/

# One-time: builds used to be signed by team 5P687673H4; the app group (widget-shared settings and the cached
# snapshot) is team-prefixed, so carry it over to the current team's container.
OLD_GROUP=~/Library/Group\ Containers/5P687673H4.app.headroom.shared
NEW_GROUP=~/Library/Group\ Containers/8XX544GLPH.app.headroom.shared
if [[ -d "$OLD_GROUP" && ! -e "$NEW_GROUP/.migrated" ]]; then
  mkdir -p "$NEW_GROUP/Library/Preferences"
  [[ -f "$OLD_GROUP/state.json" ]] && cp "$OLD_GROUP/state.json" "$NEW_GROUP/state.json"
  OLD_PLIST="$OLD_GROUP/Library/Preferences/5P687673H4.app.headroom.shared.plist"
  [[ -f "$OLD_PLIST" ]] && defaults import "$NEW_GROUP/Library/Preferences/8XX544GLPH.app.headroom.shared.plist" "$OLD_PLIST"
  touch "$NEW_GROUP/.migrated"
fi

# Register the new extension, drop any stale registration, and restart the widget host
# (chronod relaunches automatically and reloads placed widgets from the new extension).
pluginkit -a /Applications/Headroom.app/Contents/PlugIns/HeadroomWidgets.appex 2>/dev/null || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Headroom.app >/dev/null 2>&1 || true
killall chronod 2>/dev/null || true

# Remove the app bundles left in build/ (Release and any Debug ones), so Spotlight, Launchpad and
# LaunchServices only ever know the copy in /Applications. Intermediates stay for incremental builds.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
for stale in build/Build/Products/*/Headroom.app(N) build/*/Build/Products/*/Headroom.app(N); do
  "$LSREGISTER" -u "$stale" >/dev/null 2>&1 || true
  rm -rf "$stale"
done

open /Applications/Headroom.app
echo "Installed Headroom build $BUILD"
