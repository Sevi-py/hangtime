#!/bin/zsh
# Publishes dist/<version>/ (from build-release.sh): tags v<version> at HEAD, creates the GitHub release with the
# zip, DMG and checksums, then points Casks/hangtime.rb at it and pushes that to main.
#
#   scripts/publish-release.sh 1.2.0
#
# Needs gh (or GH_TOKEN) with write access. Used by .github/workflows/release.yml and scripts/release.sh --local.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${1:-}
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: $0 <major.minor.patch>"; exit 1; }
DIST=dist/$VERSION
ZIP="$DIST/Hangtime-$VERSION.zip"
DMG="$DIST/Hangtime-$VERSION.dmg"
[[ -f "$ZIP" && -f "$DMG" ]] || { echo "Run scripts/build-release.sh $VERSION first."; exit 1; }
REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')

git fetch -q --tags origin
if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
  echo "Tag v$VERSION already exists."; exit 1
fi
PREV=$(git tag --list 'v*' --sort=-v:refname | head -1)

git tag -a "v$VERSION" -m "Hangtime $VERSION"
git push -q origin "v$VERSION"
gh release create "v$VERSION" "$ZIP" "$DMG" "$DIST/SHA256SUMS" --repo "$REPO" --title "Hangtime $VERSION" \
  --verify-tag --generate-notes ${PREV:+--notes-start-tag "$PREV"}

# Point the cask at the new release, on main (CI checks out a detached commit, so switch to main first).
git fetch -q origin main
[[ "$(git branch --show-current)" == main ]] || git checkout -q -B main origin/main
git pull -q --rebase origin main
sed -i '' -E "s/^  version \".*\"/  version \"$VERSION\"/; s/^  sha256 \".*\"/  sha256 \"$SHA\"/" Casks/hangtime.rb
git add Casks/hangtime.rb
if ! git diff --cached --quiet; then
  git commit -q -m "Cask: Hangtime $VERSION"
  # Retry if someone pushed to main in the meantime.
  for attempt in 1 2 3; do
    git push -q origin main && break
    sleep 3
    git pull -q --rebase origin main
  done
fi
echo "Released https://github.com/$REPO/releases/tag/v$VERSION"
