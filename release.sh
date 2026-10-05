#!/bin/bash
# Builds a release of Cheatsheet and (with --publish) posts it on GitHub.
#
# Usage:
#   ./release.sh 1.0.0             # build and check the zip, publish nothing
#   ./release.sh 1.0.0 --publish   # also tag v1.0.0 and create the GitHub release
#
# The version must match MARKETING_VERSION in the Xcode project (bump it there
# first). Releases are ad-hoc signed: they carry no developer identity, and
# since they aren't notarized, users approve the app once in
# System Settings → Privacy & Security → Open Anyway.
set -euo pipefail

cd "$(dirname "$0")"

VERSION="${1:-}"
PUBLISH=false
[[ "${2:-}" == "--publish" ]] && PUBLISH=true

fail() { echo "error: $*" >&2; exit 1; }

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || fail "usage: ./release.sh <version> [--publish], e.g. ./release.sh 1.0.0"
TAG="v$VERSION"
OUT="build/release"
APP="$OUT/Build/Products/Release/Cheatsheet.app"
ZIP="$OUT/Cheatsheet-$VERSION.zip"

PROJECT_VERSION=$(xcodebuild -project Cheatsheet.xcodeproj -target Cheatsheet -configuration Release \
  -showBuildSettings 2>/dev/null | awk -F' = ' '/ MARKETING_VERSION /{print $2; exit}')
# "1.0" in the project matches "1.0" or "1.0.0" here.
[[ "$VERSION" == "$PROJECT_VERSION" || "$VERSION" == "$PROJECT_VERSION.0" ]] \
  || fail "version $VERSION doesn't match the app's version ($PROJECT_VERSION); set MARKETING_VERSION first"

if $PUBLISH; then
  command -v gh >/dev/null || fail "GitHub CLI not found: brew install gh, then gh auth login"
  gh auth status >/dev/null 2>&1 || fail "not signed in to GitHub: gh auth login"
  [[ -z "$(git status --porcelain)" ]] || fail "commit or stash your changes first"
  [[ "$(git branch --show-current)" == "main" ]] || fail "release from main"
  git fetch -q origin main
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || fail "push main first (local and GitHub differ)"
  git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && fail "tag $TAG already exists"
fi

echo "Building Cheatsheet ${VERSION}…"
rm -rf "$OUT"
# Ad-hoc signing ("-"): no certificate, so no name or email in the signature.
# No injected debugging entitlement, and symbols stripped as an archive would
# (they hold build-machine paths).
xcodebuild -project Cheatsheet.xcodeproj -scheme Cheatsheet -configuration Release \
  -derivedDataPath "$OUT" \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  DEPLOYMENT_POSTPROCESSING=YES STRIP_INSTALLED_PRODUCT=YES \
  build -quiet

codesign --verify --deep --strict "$APP" || fail "the built app's signature doesn't verify"
SIGNATURE=$(codesign -dvv "$APP" 2>&1)
grep -q "Signature=adhoc" <<<"$SIGNATURE" || fail "the app isn't ad-hoc signed"
! grep -q "^Authority=" <<<"$SIGNATURE" || fail "the app is signed with a certificate (it would show its name)"
ENTITLEMENTS=$(codesign -d --entitlements - "$APP" 2>/dev/null)
! grep -q "get-task-allow" <<<"$ENTITLEMENTS" || fail "the app allows debugger attachment (get-task-allow)"
PATHS=$( (grep -a -o "$HOME" "$APP/Contents/MacOS/Cheatsheet" || true) | wc -l | tr -d ' ')
[[ "$PATHS" -eq 0 ]] || echo "warning: the app still contains $PATHS paths under $HOME"

ditto -c -k --keepParent "$APP" "$ZIP"
(cd "$OUT" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
echo "Built $ZIP"

if ! $PUBLISH; then
  echo "Dry run: nothing published. Run with --publish to release $TAG."
  exit 0
fi

NOTES=$(cat <<EOF
## Install

1. Download **Cheatsheet-$VERSION.zip** below and unzip it.
2. Move **Cheatsheet.app** to Applications and open it.
3. macOS will say it can't check the app for malicious software, because it
   isn't notarized. Open **System Settings → Privacy & Security**, scroll
   down, and click **Open Anyway** next to Cheatsheet. You only do this once.

Requires macOS 26 or later.
EOF
)

git tag -a "$TAG" -m "Cheatsheet $VERSION"
git push -q origin "$TAG"
gh release create "$TAG" "$ZIP" "$ZIP.sha256" \
  --title "Cheatsheet $VERSION" \
  --notes "$NOTES" \
  --generate-notes
echo "Published $TAG"
