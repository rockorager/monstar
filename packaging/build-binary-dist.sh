#!/usr/bin/env bash
# Build the prebuilt release tarball for the host architecture.
# Run once per architecture, then ./packaging/build-source-dist.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=packaging/release-version.sh
source "$SCRIPT_DIR/release-version.sh"

ARCH="$(uname -m)"
OS="linux"
case "$ARCH" in
  x86_64 | aarch64) ;;
  *)
    echo "error: unsupported release architecture '$ARCH'" >&2
    exit 1
    ;;
esac

TARBALL_NAME="monstar-${VERSION}-${ARCH}-${OS}.tar.gz"
STAGING_DIR="dist/staging"
ARCHIVE_ROOT="monstar-${VERSION}-${ARCH}-${OS}"

echo "==> Building pre-built release binary for monstar ${TAG} (version: ${VERSION}, ${ARCH})..."
rm -rf "$STAGING_DIR" "dist/${TARBALL_NAME}"
mkdir -p "$STAGING_DIR/${ARCHIVE_ROOT}"

# Build stripped fast release prefix
zig build -Doptimize=fast -Dstrip=true -Dcpu=baseline --prefix "$STAGING_DIR/${ARCHIVE_ROOT}"

EXPECTED_VERSION="monstar ${VERSION}"
ACTUAL_VERSION=$("$STAGING_DIR/${ARCHIVE_ROOT}/bin/monstar" --version)
if [ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]; then
  echo "error: built binary reports '$ACTUAL_VERSION', expected '$EXPECTED_VERSION'" >&2
  echo "       Build release artifacts from the exact ${TAG} tag." >&2
  exit 1
fi

TERMINFO="$STAGING_DIR/${ARCHIVE_ROOT}/share/terminfo" \
  infocmp -x monstar > /dev/null

cp LICENSE README.md "$STAGING_DIR/${ARCHIVE_ROOT}/"

# The same commit gives the same archive: sorted, owned by root so packages
# need not fix ownership, dated by the commit, and gzipped without a name or
# timestamp.
echo "==> Creating release tarball dist/${TARBALL_NAME}..."
tar -C "$STAGING_DIR" --sort=name --owner=0 --group=0 --numeric-owner \
  --mtime="@$(git log -1 --format=%ct)" -cf - "${ARCHIVE_ROOT}" |
  gzip -9 -n > "dist/${TARBALL_NAME}"
echo "==> SHA256: $(sha256sum "dist/${TARBALL_NAME}" | cut -d' ' -f1)"

if [ -n "${ARTIFACTS_DIR:-}" ]; then
  mkdir -p "$ARTIFACTS_DIR"
  cp -f "dist/${TARBALL_NAME}" "$ARTIFACTS_DIR/"
  echo "==> Staged dist/${TARBALL_NAME} in $ARTIFACTS_DIR"
fi

echo "✅ Release binary built for ${TAG} (${ARCH})."
