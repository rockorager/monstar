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
SOURCE_TARBALL_NAME="monstar-${VERSION}-source.tar.gz"
STAGING_DIR="dist/staging"
ARCHIVE_ROOT="monstar-${VERSION}-${ARCH}-${OS}"

echo "==> Building pre-built release binary for monstar ${TAG} (version: ${VERSION})..."
rm -rf "$STAGING_DIR" dist/monstar-*.tar.gz \
  packaging/arch/PKGBUILD packaging/arch/PKGBUILD.source packaging/arch/PKGBUILD.git
mkdir -p "$STAGING_DIR/${ARCHIVE_ROOT}"

# Build stripped ReleaseFast release prefix
zig build -Doptimize=ReleaseFast -Dstrip=true --prefix "$STAGING_DIR/${ARCHIVE_ROOT}"

EXPECTED_VERSION="monstar ${VERSION}"
ACTUAL_VERSION=$("$STAGING_DIR/${ARCHIVE_ROOT}/bin/monstar" --version)
if [ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]; then
  echo "error: built binary reports '$ACTUAL_VERSION', expected '$EXPECTED_VERSION'" >&2
  echo "       Build release artifacts from the exact ${TAG} tag." >&2
  exit 1
fi

TERMINFO="$STAGING_DIR/${ARCHIVE_ROOT}/share/terminfo" \
  infocmp -x monstar >/dev/null

echo "==> Creating release tarball dist/${TARBALL_NAME}..."
tar -czf "dist/${TARBALL_NAME}" -C "$STAGING_DIR" "${ARCHIVE_ROOT}"

SHA256=$(sha256sum "dist/${TARBALL_NAME}" | cut -d' ' -f1)
echo "==> Calculated SHA256 checksum: ${SHA256}"

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
GIT_VERSION=$(git describe --long --tags --match 'v[0-9]*' | \
  sed -E 's/^v//; s/-([0-9]+)-g/.r\1.g/')
sed "s/@VERSION@/${VERSION}/g; s/@SHA256@/${SHA256}/g" \
  packaging/arch/monstar-bin.PKGBUILD.in > packaging/arch/PKGBUILD
sed "s/@VERSION@/${VERSION}/g; s/@SHA256@/${SOURCE_SHA256}/g" \
  packaging/arch/monstar.PKGBUILD.in > packaging/arch/PKGBUILD.source
sed "s/@VERSION@/${GIT_VERSION}/g" \
  packaging/arch/monstar-git.PKGBUILD.in > packaging/arch/PKGBUILD.git


# Stage all artifacts if ARTIFACTS_DIR is set
if [ -n "${ARTIFACTS_DIR:-}" ]; then
  mkdir -p "$ARTIFACTS_DIR"
  cp -f "dist/${TARBALL_NAME}" "dist/${SOURCE_TARBALL_NAME}" "$ARTIFACTS_DIR/"
  cp -f packaging/arch/PKGBUILD packaging/arch/PKGBUILD.source \
    packaging/arch/PKGBUILD.git "$ARTIFACTS_DIR/"
  echo "==> Staged release archives and AUR PKGBUILDs in $ARTIFACTS_DIR"
fi

echo "✅ Release distributions and AUR PKGBUILDs built for ${TAG}."
