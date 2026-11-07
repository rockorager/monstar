#!/bin/bash
export XDG_RUNTIME_DIR=/tmp/mvk-run WAYLAND_DISPLAY=wayland-1 SWAYSOCK=$(ls /tmp/mvk-run/sway-ipc.*)
plane() { grep -A30 "plane\[206\]" /sys/kernel/debug/dri/1/state | sed -n 1,30p | grep -E "fb=|pitch|size\[" | tr -d '\t' | tr '\n' ' '; echo; }
setsid ./vkgrid/vkgrid scroll > /tmp/mvk-vk.log 2>&1 < /dev/null &
sleep 1.5
swaymsg '[app_id="vkgrid"] fullscreen enable' >/dev/null
sleep 1; echo "before recreate: $(plane)"
kill -USR1 $(pgrep -x vkgrid)
sleep 2; echo "after recreate:  $(plane)"
tail -200 /tmp/mvk-sway.log | awk '{$1="";print}' | sort | uniq -c | sort -rn | head -4
