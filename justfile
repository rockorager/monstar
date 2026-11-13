# Monstar: a Wayland terminal emulator. `just --list` shows the recipes.
# `mise install` installs the toolchain mise.toml pins.
#
# `zig` is the compiler: bs for development builds, or upstream Zig where
# bs is not installed. `just zig=zig test` uses upstream Zig anyway, as CI
# does, since releases and packagers build with it.

zig := `command -v bs >/dev/null && echo bs || echo zig`

# The Wayland schemas Monstar's client bindings are generated from. Debian
# and Ubuntu 24.04 ship older ones, so `just setup` fetches these, and every
# recipe finds them first.

wayland_version := "1.25.0"
wayland_sha256 := "c065f040afdff3177680600f249727e41a1afc22fccf27222f15f5306faa1f03"
wayland_protocols_version := "1.49"
wayland_protocols_sha256 := "ec4c8f74942d6dff7ace8b4ce4764f0ef9ff618a935d974ea77edee2ad240b14"
cache := cache_directory() / "monstar"
pkgconfig := cache / "pkgconfig"

export PKG_CONFIG_PATH := if env("PKG_CONFIG_PATH", "") == "" { pkgconfig } else { pkgconfig + ":" + env("PKG_CONFIG_PATH") }

[private]
default:
    @just --list

[doc("Fetch the pinned Wayland schemas into the user cache; `mise install` installs the rest")]
[group("build")]
setup:
    #!/usr/bin/env bash
    set -euo pipefail
    cache="{{ cache }}"
    mkdir -p "{{ pkgconfig }}"
    # fetch NAME VERSION SHA256 URL: the release unpacked in $cache/NAME-VERSION.
    fetch() {
        [ -d "$cache/$1-$2" ] && return
        echo "fetching $1 $2"
        local tmp
        tmp=$(mktemp -d)
        curl -fsSL --retry 5 --retry-delay 2 -o "$tmp/src.tar.xz" "$4"
        echo "$3  $tmp/src.tar.xz" | sha256sum --check --quiet -
        tar -C "$tmp" -xf "$tmp/src.tar.xz"
        mv "$tmp/$1-$2" "$cache/$1-$2"
        rm -rf "$tmp"
    }
    fetch wayland {{ wayland_version }} {{ wayland_sha256 }} \
        https://gitlab.freedesktop.org/wayland/wayland/-/releases/{{ wayland_version }}/downloads/wayland-{{ wayland_version }}.tar.xz
    fetch wayland-protocols {{ wayland_protocols_version }} {{ wayland_protocols_sha256 }} \
        https://gitlab.freedesktop.org/wayland/wayland-protocols/-/releases/{{ wayland_protocols_version }}/downloads/wayland-protocols-{{ wayland_protocols_version }}.tar.xz
    cat >"{{ pkgconfig }}/wayland-scanner.pc" <<EOF
    prefix=$cache/wayland-{{ wayland_version }}
    pkgdatadir=\${prefix}/protocol

    Name: Wayland Scanner Data
    Description: Wayland core protocol files
    Version: {{ wayland_version }}
    EOF
    cat >"{{ pkgconfig }}/wayland-protocols.pc" <<EOF
    prefix=$cache/wayland-protocols-{{ wayland_protocols_version }}
    pkgdatadir=\${prefix}

    Name: Wayland Protocols
    Description: Wayland protocol files
    Version: {{ wayland_protocols_version }}
    EOF
    echo "wayland-scanner $(pkg-config --modversion wayland-scanner), wayland-protocols $(pkg-config --modversion wayland-protocols)"

[doc("Build Monstar into zig-out/bin/monstar")]
[group("build")]
build *ARGS:
    {{ zig }} build {{ ARGS }}

[doc("Build and run Monstar on the Wayland display")]
[group("build")]
run *ARGS:
    {{ zig }} build run -- {{ ARGS }}

[doc("Install a release build of Monstar, its desktop entry, icon, man pages, and themes under PREFIX")]
[group("build")]
install prefix="~/.local":
    zig build -Doptimize=fast -p {{ prefix }}

[doc("Build the release tarball for this machine's architecture into dist/")]
[group("build")]
dist:
    ./packaging/build-binary-dist.sh

[doc("The unit tests, and the formatting check the test step includes")]
[group("test")]
test *ARGS:
    {{ zig }} build test --summary failures {{ ARGS }}

[doc("Lint Zig, shell, and this justfile: zig fmt, shellcheck, shfmt, and just --fmt")]
[group("lint")]
lint:
    zig fmt --check build.zig build.zig.zon src
    shellcheck .agents/setup packaging/*.sh
    shfmt -i 2 -ci -sr --diff .agents/setup packaging/*.sh
    just --unstable --fmt --check

[doc("Format everything lint checks")]
[group("lint")]
fmt:
    zig fmt build.zig build.zig.zon src
    shfmt -i 2 -ci -sr --write .agents/setup packaging/*.sh
    just --unstable --fmt

[doc("Release origin/main as vVERSION, the next patch version by default; CI builds and publishes it")]
[group("release")]
release version="":
    #!/usr/bin/env bash
    set -euo pipefail
    git fetch -q --tags origin main
    sha=$(git rev-parse origin/main)
    if tag=$(git describe --exact-match --tags --match 'v[0-9]*' "$sha" 2>/dev/null); then
        echo "origin/main is released already, as $tag" >&2
        exit 1
    fi
    # Only a commit whose CI passed is released.
    ci=$(gh run list --workflow ci.yml --commit "$sha" --json conclusion --jq '.[0].conclusion // "missing"')
    if [ "$ci" != success ]; then
        echo "CI for origin/main ${sha:0:8} is $ci, not success" >&2
        exit 1
    fi
    # The tags are the versions: the newest's patch, one up, unless told.
    last=$(git tag -l 'v[0-9]*' --sort=-v:refname | head -1)
    version="{{ version }}"
    if [ -z "$version" ]; then
        IFS=. read -r major minor patch <<<"${last:-v0.0.0}"
        version=${major#v}.$minor.$((patch + 1))
    fi
    if ! [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "version $version is not X.Y.Z" >&2
        exit 1
    fi
    if [ -n "$last" ] && [ "$(printf '%s\n' "$last" "v$version" | sort -V | tail -1)" != "v$version" ]; then
        echo "v$version is not newer than $last" >&2
        exit 1
    fi
    if git cat-file -e "$sha:docs/releases/$version.md" 2>/dev/null; then
        echo "release notes: docs/releases/$version.md"
    else
        echo "release notes: none in docs/releases/$version.md, so the release lists the commits since ${last:-the start}"
    fi
    # The release commit records the version in build.zig.zon, which builds
    # from a source archive report. It is written with a scratch index, so
    # this checkout and its branch stay as they are.
    index=$(mktemp)
    trap 'rm -f "$index"' EXIT
    export GIT_INDEX_FILE=$index
    git read-tree "$sha"
    zon=$(git show "$sha:build.zig.zon" |
        sed "s/^    \.version = \"[^\"]*\",\$/    .version = \"$version\",/" |
        git hash-object -w --stdin)
    git update-index --cacheinfo "100644,$zon,build.zig.zon"
    tree=$(git write-tree)
    unset GIT_INDEX_FILE
    refs=("v$version")
    if [ "$tree" = "$(git rev-parse "$sha^{tree}")" ]; then
        commit=$sha
        echo "build.zig.zon already says $version, so v$version tags origin/main itself"
    else
        commit=$(git commit-tree "$tree" -p "$sha" -m "release: $version")
        git diff --stat "$sha" "$commit"
        refs+=("$commit:refs/heads/main")
    fi
    # Signed, as every Monstar release is; without a signing key nothing is
    # tagged or pushed.
    git tag -s "v$version" -m "Monstar $version" "$commit"
    # Atomically, so main never gets a release commit without its tag. If main
    # moved since the fetch, nothing is pushed and the tag goes too.
    if ! git push -q --atomic origin "${refs[@]}"; then
        git tag -d "v$version" >/dev/null
        exit 1
    fi
    echo "pushed v$version; the Release workflow builds and publishes it:"
    echo "https://github.com/rockorager/monstar/actions/workflows/release.yml"

[doc("The build, the tests, and lint")]
[group("ci")]
ci: build test lint
