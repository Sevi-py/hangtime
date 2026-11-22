#!/bin/zsh
# Starts a Hangtime release.
#
#   scripts/release.sh 1.2.0           bump MARKETING_VERSION in project.yml, commit and push to main. GitHub Actions
#                                      (.github/workflows/release.yml) then builds, signs, notarizes and publishes.
#   scripts/release.sh 1.2.0 --local   bump, commit and push, then build and publish from this Mac instead
#                                      (needs Xcode signed in to team 8XX544GLPH and the hangtime-notary profile).
#   scripts/build-release.sh 1.2.0     dry run: signed, notarized artifacts in dist/1.2.0, nothing published.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${1:-}
MODE=${2:-}
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: $0 <major.minor.patch> [--local]"; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "Working tree is not clean. Commit first."; exit 1; }
[[ "$(git branch --show-current)" == main ]] || { echo "Release from main."; exit 1; }
git pull -q --rebase origin main
git fetch -q --tags origin
git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null && { echo "v$VERSION is already released."; exit 1; }
LATEST=$(git tag --list 'v*' --sort=-v:refname | head -1 | sed 's/^v//')
if [[ -n "$LATEST" && "$(printf '%s\n%s\n' "$LATEST" "$VERSION" | sort -V | tail -1)" != "$VERSION" ]]; then
  echo "$VERSION is not newer than the latest release $LATEST."; exit 1
fi

if [[ "$MODE" == "--local" ]]; then
  # Build first, so a failed build or notarization doesn't leave a version bump on main.
  scripts/build-release.sh "$VERSION"
fi

sed -i '' -E "s/MARKETING_VERSION: \"[^\"]+\"/MARKETING_VERSION: \"$VERSION\"/" project.yml
xcodegen generate >/dev/null
git add project.yml Hangtime.xcodeproj
# --local publishes from here, so keep the release workflow from also picking up this push.
if [[ "$MODE" == "--local" ]]; then
  git commit -q -m "Release $VERSION [skip ci]"
else
  git commit -q -m "Release $VERSION"
fi
git push -q origin main

if [[ "$MODE" == "--local" ]]; then
  scripts/publish-release.sh "$VERSION"
else
  REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
  echo "Pushed the version bump. GitHub Actions is building the release:"
  echo "  https://github.com/$REPO/actions/workflows/release.yml"
fi
