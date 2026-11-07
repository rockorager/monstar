#!/bin/bash
# usage: hypr-up.sh GAPS
RUN=/tmp/mvk-run; rm -rf $RUN; mkdir -p $RUN; chmod 700 $RUN
sed "s/@GAPS@/${1:-0}/" "$(dirname "$0")/hypr.lua.in" > $RUN/hyprland.lua
chvt 63
export XDG_RUNTIME_DIR=$RUN LIBSEAT_BACKEND=seatd AQ_DRM_DEVICES=/dev/dri/card1
setsid seatd-launch -- Hyprland --config $RUN/hyprland.lua --i-am-really-stupid > /tmp/mvk-hypr.log 2>&1 < /dev/null &
for i in $(seq 100); do ls $RUN/wayland-* >/dev/null 2>&1 && break; sleep 0.1; done
sleep 1; ls $RUN; pgrep -x Hyprland
