#!/usr/bin/env bash
set -euo pipefail

# Read environment metadata (with fallbacks for standalone execution)
JOB_ID="${PICI_JOB:-local}"
REPO="${PICI_REPO:-monstar}"
BRANCH="${PICI_BRANCH:-main}"
COMMIT="${PICI_COMMIT:-dev}"
export ZMX_SESSION_PREFIX="${ZMX_SESSION_PREFIX:-local.}"
export PICI_ARTIFACTS_DIR="${PICI_ARTIFACTS_DIR:-/tmp/pici-artifacts/$REPO/$JOB_ID}"
export ARTIFACTS_DIR="$PICI_ARTIFACTS_DIR"

echo "Running CI & packaging for $REPO ($BRANCH@$COMMIT, job: $JOB_ID)"
echo "Staging artifacts into $ARTIFACTS_DIR"

# 1. Serial setup/format check step
zmx run format zig build fmt

# 2. Serial unit test step
zmx run test zig build test --summary all

# 3. Build release artifacts only for a pushed tag.
if [ "${PICI_EVENT:-}" = "git.tag" ]; then
  zmx run build-binary ./packaging/build-binary-dist.sh
else
  echo "Skipping release packaging for ${PICI_EVENT:-local} event"
fi

zmx wait "*"

if [ "${PICI_EVENT:-}" = "git.tag" ]; then
  echo "✅ Artifacts staged in $ARTIFACTS_DIR"
  echo "   To publish a release: ./packaging/upload-release.sh <tag> [artifacts-dir]"
fi
