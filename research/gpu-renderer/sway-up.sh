#!/bin/bash
# usage: sway-up.sh gles2|vulkan [scanout=1|0]
set -e
R=${1:-gles2}; SC=${2:-1}
RUN=/tmp/mvk-run; rm -rf $RUN; mkdir -p $RUN; chmod 700 $RUN
chvt 63
export XDG_RUNTIME_DIR=$RUN LIBSEAT_BACKEND=seatd WLR_BACKENDS=drm,libinput WLR_DRM_DEVICES=/dev/dri/card1 WLR_RENDERER=$R WLR_LIBINPUT_NO_DEVICES=1
[ "$SC" = 0 ] && export WLR_SCENE_DISABLE_DIRECT_SCANOUT=1
setsid seatd-launch -- sway ${SWAY_DEBUG:+-d} -c "$(cd "$(dirname "$0")" && pwd)/${SWAY_CONF:-sway.conf}" > /tmp/mvk-sway.log 2>&1 < /dev/null &
for i in $(seq 100); do [ -S $RUN/wayland-1 ] && break; sleep 0.1; done
ls $RUN; pgrep -x sway
