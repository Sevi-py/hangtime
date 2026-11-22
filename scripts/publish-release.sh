#!/bin/zsh
# Publishes dist/<version>/ (from build-release.sh): tags v<version> at HEAD, creates the GitHub release with the
# zip, DMG and checksums, then points the Homebrew cask in the tap (github.com/Sevi-py/homebrew-tap) at it.
#
#   scripts/publish-release.sh 1.2.0
#
# Needs gh (or GH_TOKEN) with write access to this repo. The tap is pushed over SSH with TAP_DEPLOY_KEY_PATH (a
# write deploy key, as in CI), or otherwise over HTTPS with your git credentials.
# Used by .github/workflows/release.yml and scripts/release.sh --local.
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
if gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1; then
  echo "v$VERSION is already released."; exit 1
fi
PREV=$(git tag --list 'v*' --sort=-v:refname | grep -vx "v$VERSION" | head -1 || true)

# A run that failed after tagging left the tag behind: reuse it instead of tagging again.
if ! git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
  git tag -a "v$VERSION" -m "Hangtime $VERSION"
  git push -q origin "v$VERSION"
fi
# zsh doesn't word-split expansions, so optional flags go in an array.
notes=(--generate-notes)
[[ -n "$PREV" ]] && notes+=(--notes-start-tag "$PREV")
gh release create "v$VERSION" "$ZIP" "$DMG" "$DIST/SHA256SUMS" --repo "$REPO" --title "Hangtime $VERSION" \
  --verify-tag "${notes[@]}"

# Point the cask in the tap at the new release.
TAP=$(mktemp -d)
trap 'rm -rf "$TAP"' EXIT
if [[ -n "${TAP_DEPLOY_KEY_PATH:-}" ]]; then
  export GIT_SSH_COMMAND="ssh -i $TAP_DEPLOY_KEY_PATH -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
  TAP_URL=git@github.com:Sevi-py/homebrew-tap.git
else
  TAP_URL=https://github.com/Sevi-py/homebrew-tap.git
fi
git clone -q --depth 1 "$TAP_URL" "$TAP"
sed -i '' -E "s/^  version \".*\"/  version \"$VERSION\"/; s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$TAP/Casks/hangtime.rb"
if ! git -C "$TAP" diff --quiet; then
  git -C "$TAP" commit -q -am "Hangtime $VERSION"
  # Retry if someone pushed to the tap in the meantime.
  for attempt in 1 2 3; do
    git -C "$TAP" push -q origin HEAD:main && break
    sleep 3
    git -C "$TAP" pull -q --rebase origin main
  done
fi
echo "Released https://github.com/$REPO/releases/tag/v$VERSION"
