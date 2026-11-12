#!/usr/bin/env bash
# Create the release source archive and generate the AUR PKGBUILDs from it and
# the prebuilt tarballs that ./packaging/build-binary-dist.sh left in dist/
# for every architecture.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=packaging/release-version.sh
source "$SCRIPT_DIR/release-version.sh"

SOURCE_TARBALL_NAME="monstar-${VERSION}-source.tar.gz"
rm -f "dist/${SOURCE_TARBALL_NAME}" \
  packaging/arch/PKGBUILD packaging/arch/PKGBUILD.source packaging/arch/PKGBUILD.git
mkdir -p dist

binary_sha256() {
  local tarball="dist/monstar-${VERSION}-$1-linux.tar.gz"
  if [ ! -f "$tarball" ]; then
    echo "error: $tarball not found; run ./packaging/build-binary-dist.sh on $1" >&2
    exit 1
  fi
  sha256sum "$tarball" | cut -d' ' -f1
}
SHA256_X86_64=$(binary_sha256 x86_64)
SHA256_AARCH64=$(binary_sha256 aarch64)

# Create a controlled source archive instead of relying on GitHub's generated
# repository archives, whose checksums are not release artifacts we own.
echo "==> Creating source archive dist/${SOURCE_TARBALL_NAME}..."
git archive \
  --format=tar.gz \
  --prefix="monstar-${VERSION}/" \
  --output="dist/${SOURCE_TARBALL_NAME}" \
  HEAD
SOURCE_SHA256=$(sha256sum "dist/${SOURCE_TARBALL_NAME}" | cut -d' ' -f1)

echo "==> Generating AUR PKGBUILDs..."
GIT_VERSION=$(git describe --long --tags --match 'v[0-9]*' |
  sed -E 's/^v//; s/-([0-9]+)-g/.r\1.g/')
sed "s/@VERSION@/${VERSION}/g; s/@SHA256_X86_64@/${SHA256_X86_64}/g; s/@SHA256_AARCH64@/${SHA256_AARCH64}/g" \
  packaging/arch/monstar-bin.PKGBUILD.in > packaging/arch/PKGBUILD
sed "s/@VERSION@/${VERSION}/g; s/@SHA256@/${SOURCE_SHA256}/g" \
  packaging/arch/monstar.PKGBUILD.in > packaging/arch/PKGBUILD.source
sed "s/@VERSION@/${GIT_VERSION}/g" \
  packaging/arch/monstar-git.PKGBUILD.in > packaging/arch/PKGBUILD.git

if [ -n "${ARTIFACTS_DIR:-}" ]; then
  mkdir -p "$ARTIFACTS_DIR"
  cp -f "dist/${SOURCE_TARBALL_NAME}" "$ARTIFACTS_DIR/"
  cp -f packaging/arch/PKGBUILD packaging/arch/PKGBUILD.source \
    packaging/arch/PKGBUILD.git "$ARTIFACTS_DIR/"
  echo "==> Staged source archive and AUR PKGBUILDs in $ARTIFACTS_DIR"
fi

echo "✅ Source archive and AUR PKGBUILDs built for ${TAG}."
