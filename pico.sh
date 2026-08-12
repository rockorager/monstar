#!/usr/bin/env bash
set -euo pipefail

# Read environment metadata (with fallbacks for standalone execution)
JOB_ID="${PICI_JOB:-local}"
REPO="${PICI_REPO:-monstar}"
BRANCH="${PICI_BRANCH:-main}"
COMMIT="${PICI_COMMIT:-dev}"
ZMX_SESSION_PREFIX="${ZMX_SESSION_PREFIX:-local.}"
export PICI_ARTIFACTS_DIR="${PICI_ARTIFACTS_DIR:-/tmp/pici-artifacts/$REPO/$JOB_ID}"
export ARTIFACTS_DIR="$PICI_ARTIFACTS_DIR"

echo "Running CI & packaging for $REPO ($BRANCH@$COMMIT, job: $JOB_ID)"
echo "Staging artifacts into $ARTIFACTS_DIR"

# 1. Serial setup/format check step
zmx run format zig build fmt

# 2. Serial unit test step
zmx run test zig build test --summary all

# 3. Build pre-built binary release archive, bake SHA256, and stage all artifacts
zmx run build-binary ./packaging/build-binary-dist.sh

zmx wait "*"

echo "✅ Artifacts staged in $ARTIFACTS_DIR"
echo "   To publish a release: ./packaging/upload-release.sh <tag> [artifacts-dir]"
