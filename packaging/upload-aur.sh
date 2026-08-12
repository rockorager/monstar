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
(cd "$AUR_DIR" && makepkg --printsrcinfo > .SRCINFO)

VERSION=$(grep '^pkgver=' "$AUR_DIR/PKGBUILD" | cut -d= -f2)

echo "==> Committing and pushing v${VERSION}..."
cd "$AUR_DIR"
git add PKGBUILD .SRCINFO
git commit -m "Update to v${VERSION}"
git push

echo "✅ monstar-bin v${VERSION} published to AUR."
