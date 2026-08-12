#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# Resolve version from PICI_TAG or build.zig.zon
DEFAULT_VER=$(grep -m1 '\.version\s*=' build.zig.zon | sed 's/.*"\(.*\)".*/\1/')
RAW_TAG="${PICI_TAG:-v$DEFAULT_VER}"
if [[ "$RAW_TAG" =~ ^v ]]; then
  TAG="$RAW_TAG"
  VERSION="${RAW_TAG#v}"
else
  VERSION="$RAW_TAG"
  TAG="v$RAW_TAG"
fi

ARCH="x86_64"
OS="linux"

TARBALL_NAME="monstar-${VERSION}-${ARCH}-${OS}.tar.gz"
STAGING_DIR="dist/staging"
ARCHIVE_ROOT="monstar-${VERSION}-${ARCH}-${OS}"

echo "==> Building pre-built release binary for monstar ${TAG} (version: ${VERSION})..."
rm -rf "$STAGING_DIR" dist/monstar-*.tar.gz
mkdir -p "$STAGING_DIR/${ARCHIVE_ROOT}"

# Build ReleaseFast release prefix
zig build -Doptimize=ReleaseFast --prefix "$STAGING_DIR/${ARCHIVE_ROOT}"

EXPECTED_VERSION="monstar ${VERSION}"
ACTUAL_VERSION=$("$STAGING_DIR/${ARCHIVE_ROOT}/bin/monstar" --version)
if [ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]; then
  echo "error: built binary reports '$ACTUAL_VERSION', expected '$EXPECTED_VERSION'" >&2
  echo "       Build release artifacts from the exact ${TAG} tag." >&2
  exit 1
fi

echo "==> Creating release tarball dist/${TARBALL_NAME}..."
tar -czf "dist/${TARBALL_NAME}" -C "$STAGING_DIR" "${ARCHIVE_ROOT}"

SHA256=$(sha256sum "dist/${TARBALL_NAME}" | cut -d' ' -f1)
echo "==> Calculated SHA256 checksum: ${SHA256}"

# Generate PKGBUILD from template
echo "==> Generating packaging/arch/PKGBUILD from template..."
sed "s/@VERSION@/${VERSION}/g; s/@SHA256@/${SHA256}/g" \
  packaging/arch/PKGBUILD.in > packaging/arch/PKGBUILD


# Stage all artifacts if ARTIFACTS_DIR is set
if [ -n "${ARTIFACTS_DIR:-}" ]; then
  mkdir -p "$ARTIFACTS_DIR"
  cp -f "dist/${TARBALL_NAME}"    "$ARTIFACTS_DIR/"
  cp -f "packaging/arch/PKGBUILD" "$ARTIFACTS_DIR/"
  echo "==> Staged artifacts in $ARTIFACTS_DIR: ${TARBALL_NAME}, PKGBUILD"
fi

echo "✅ Pre-built binary distribution built for ${TAG} and SHA256 (${SHA256}) baked into package definitions."
