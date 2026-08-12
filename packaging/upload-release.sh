#!/usr/bin/env bash
# Upload release assets to GitHub Releases.
# Usage: ./packaging/upload-release.sh <tag> [artifacts-dir]
#
# Arguments:
#   tag           Git tag for the release, e.g. v0.2.1
#   artifacts-dir Directory containing built artifacts (default: dist/)
#
# Requires: gh CLI authenticated with a GITHUB_TOKEN or GH_TOKEN env var.
set -euo pipefail

RELEASE_TAG="${1:-}"
if [ -z "$RELEASE_TAG" ]; then
  echo "error: tag argument is required (e.g. v0.2.1)" >&2
  exit 1
fi

# Normalize tag: ensure it starts with 'v'
[[ "$RELEASE_TAG" =~ ^v ]] || RELEASE_TAG="v$RELEASE_TAG"
VERSION="${RELEASE_TAG#v}"

ARTIFACTS_DIR="${2:-${ARTIFACTS_DIR:-dist}}"

TARBALL="$ARTIFACTS_DIR/monstar-${VERSION}-x86_64-linux.tar.gz"

if [ ! -f "$TARBALL" ]; then
  echo "error: tarball not found: $TARBALL" >&2
  echo "       Run ./packaging/build-binary-dist.sh first." >&2
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "error: gh CLI not found; install it from https://cli.github.com" >&2
  exit 1
fi

NOTES_FILE="docs/releases/${VERSION}.md"

echo "==> Uploading $TARBALL to GitHub Release $RELEASE_TAG..."
if gh release view "$RELEASE_TAG" >/dev/null 2>&1; then
  gh release upload "$RELEASE_TAG" "$TARBALL" --clobber
else
  if [ -f "$NOTES_FILE" ]; then
    gh release create "$RELEASE_TAG" "$TARBALL" --title "Monstar $VERSION" --notes-file "$NOTES_FILE"
  else
    gh release create "$RELEASE_TAG" "$TARBALL" --title "Monstar $VERSION" --generate-notes
  fi
fi

echo "✅ Released $TARBALL to GitHub Release $RELEASE_TAG."
