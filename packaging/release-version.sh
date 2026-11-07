# shellcheck shell=bash disable=SC2034
# Sourced by the release scripts: sets TAG and VERSION from PICI_TAG, or from
# build.zig.zon when PICI_TAG is unset.
DEFAULT_VER=$(grep -m1 '\.version\s*=' build.zig.zon | sed 's/.*"\(.*\)".*/\1/')
RAW_TAG="${PICI_TAG:-v$DEFAULT_VER}"
if [[ "$RAW_TAG" =~ ^v ]]; then
  TAG="$RAW_TAG"
  VERSION="${RAW_TAG#v}"
else
  VERSION="$RAW_TAG"
  TAG="v$RAW_TAG"
fi
