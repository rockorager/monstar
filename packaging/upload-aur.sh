#!/usr/bin/env bash
# Push the generated PKGBUILD to the monstar-bin AUR repository.
# Usage: ./packaging/upload-aur.sh [artifacts-dir]
#
# Arguments:
#   artifacts-dir  Directory containing the generated PKGBUILD (default: dist/)
#
# Prerequisites:
#   - SSH key registered at https://aur.archlinux.org/account
#   - makepkg available (for generating .SRCINFO)
#   - AUR package 'monstar-bin' already created at https://aur.archlinux.org
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ARTIFACTS_DIR="${1:-${ARTIFACTS_DIR:-$REPO_ROOT/dist}}"
PKGBUILD="$ARTIFACTS_DIR/PKGBUILD"

if [ ! -f "$PKGBUILD" ]; then
  echo "error: PKGBUILD not found at $PKGBUILD" >&2
  echo "       Run ./packaging/build-binary-dist.sh first." >&2
  exit 1
fi

AUR_DIR="$(mktemp -d)"
trap 'rm -rf "$AUR_DIR"' EXIT

echo "==> Cloning AUR repository monstar-bin..."
git clone ssh://aur@aur.archlinux.org/monstar-bin.git "$AUR_DIR"

echo "==> Copying PKGBUILD..."
cp -f "$PKGBUILD" "$AUR_DIR/PKGBUILD"

echo "==> Generating .SRCINFO..."
if command -v makepkg >/dev/null 2>&1; then
  (cd "$AUR_DIR" && makepkg --printsrcinfo > .SRCINFO)
elif command -v docker >/dev/null 2>&1; then
  echo "==> makepkg not found on host, using docker (archlinux:latest)..."
  docker run --rm \
    --user "$(id -u):$(id -g)" \
    --env HOME=/tmp \
    --volume "$AUR_DIR:/pkg" \
    --workdir /pkg \
    archlinux:latest makepkg --printsrcinfo > "$AUR_DIR/.SRCINFO"
else
  echo "error: neither makepkg nor docker is available to generate .SRCINFO" >&2
  exit 1
fi

VERSION=$(grep '^pkgver=' "$AUR_DIR/PKGBUILD" | cut -d= -f2)

echo "==> Committing and pushing v${VERSION}..."
cd "$AUR_DIR"
git config user.name "Tim Culverhouse"
git config user.email "tim@timculverhouse.com"
git add PKGBUILD .SRCINFO
if git diff --staged --quiet; then
  echo "==> No changes detected in PKGBUILD or .SRCINFO, already up to date."
else
  git commit -m "Update to v${VERSION}"
  git push origin master
  echo "✅ monstar-bin v${VERSION} published to AUR."
fi
