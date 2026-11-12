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

[doc("The build, the tests, and lint")]
[group("ci")]
ci: build test lint
