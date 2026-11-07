#!/bin/bash
# Headless 3840x2160@120 sway rendering on the real GPU (no scanout).
R=${1:-gles2}
RUN=/tmp/mvk-run; rm -rf $RUN; mkdir -p $RUN; chmod 700 $RUN
export XDG_RUNTIME_DIR=$RUN WLR_BACKENDS=headless WLR_RENDER_DRM_DEVICE=/dev/dri/renderD128 WLR_RENDERER=$R
setsid sway -c "$(cd "$(dirname "$0")" && pwd)/sway-4k.conf" > /tmp/mvk-sway.log 2>&1 < /dev/null &
for i in $(seq 100); do [ -S $RUN/wayland-1 ] && break; sleep 0.1; done
pgrep -x sway
