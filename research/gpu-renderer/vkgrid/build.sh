#!/bin/sh
set -e
cd "$(dirname "$0")"
glslc -O grid.vert -mfmt=c -o vert.inc && glslc -O grid.frag -mfmt=c -o frag.inc
{ echo "static const uint32_t grid_vert[] = "; cat vert.inc; echo ";"; } > grid.vert.h
{ echo "static const uint32_t grid_frag[] = "; cat frag.inc; echo ";"; } > grid.frag.h
wayland-scanner client-header /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml xdg-shell-client-protocol.h
wayland-scanner private-code /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml xdg-shell-protocol.c
cc -O2 -Wall -Wextra -o vkgrid vkgrid.c xdg-shell-protocol.c $(pkg-config --cflags --libs freetype2 vulkan wayland-client) -lpthread
