#!/usr/bin/env bash
# Push a generated PKGBUILD to its AUR repository.
# Usage: ./packaging/upload-aur.sh <package> <PKGBUILD>
#
# Arguments:
#   package   AUR package name (monstar, monstar-bin, or monstar-git)
#   PKGBUILD  Generated PKGBUILD to publish
#
# Prerequisites:
#   - SSH key registered at https://aur.archlinux.org/account
#   - makepkg available (for generating .SRCINFO)
#   - The AUR package already exists
set -euo pipefail

AUR_PACKAGE="${1:-}"
PKGBUILD="${2:-}"

case "$AUR_PACKAGE" in
  monstar|monstar-bin|monstar-git) ;;
  *)
    echo "usage: $0 <monstar|monstar-bin|monstar-git> <PKGBUILD>" >&2
    exit 1
    ;;
esac

if [ -z "$PKGBUILD" ] || [ ! -f "$PKGBUILD" ]; then
  echo "error: PKGBUILD not found at $PKGBUILD" >&2
  echo "       Run ./packaging/build-source-dist.sh first." >&2
  exit 1
fi

AUR_DIR="$(mktemp -d)"
trap 'rm -rf "$AUR_DIR"' EXIT

echo "==> Cloning AUR repository ${AUR_PACKAGE}..."
git clone "ssh://aur@aur.archlinux.org/${AUR_PACKAGE}.git" "$AUR_DIR"

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
  echo "✅ ${AUR_PACKAGE} v${VERSION} published to AUR."
fi
