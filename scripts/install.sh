#!/bin/zsh
# Builds Hangtime (Release), replaces /Applications/Hangtime.app and makes running widgets pick up the new build.
set -euo pipefail
cd "$(dirname "$0")/.."

# A fresh build number per install, so WidgetKit/chronod treat it as a new extension version.
BUILD=$(date +%Y%m%d%H%M%S)

xcodegen generate >/dev/null
xcodebuild -project Hangtime.xcodeproj -scheme Hangtime -configuration Release -derivedDataPath build \
  -allowProvisioningUpdates CURRENT_PROJECT_VERSION="$BUILD" build | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
APP=build/Build/Products/Release/Hangtime.app
[[ -d "$APP" ]] || { echo "Build failed"; exit 1; }

# Quit the app and the old widget extension process.
pkill -x Hangtime 2>/dev/null || true
pkill -f "HangtimeWidgets.appex" 2>/dev/null || true
sleep 1

rm -rf /Applications/Hangtime.app
cp -R "$APP" /Applications/

# Register the new extension, drop any stale registration, and restart the widget host
# (chronod relaunches automatically and reloads placed widgets from the new extension).
pluginkit -a /Applications/Hangtime.app/Contents/PlugIns/HangtimeWidgets.appex 2>/dev/null || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Hangtime.app >/dev/null 2>&1 || true
killall chronod 2>/dev/null || true

# Remove the app bundles left in build/ (Release and any Debug ones), so Spotlight, Launchpad and
# LaunchServices only ever know the copy in /Applications. Intermediates stay for incremental builds.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
for stale in build/Build/Products/*/Hangtime.app(N) build/*/Build/Products/*/Hangtime.app(N); do
  "$LSREGISTER" -u "$stale" >/dev/null 2>&1 || true
  rm -rf "$stale"
done

open /Applications/Hangtime.app
echo "Installed Hangtime build $BUILD"
