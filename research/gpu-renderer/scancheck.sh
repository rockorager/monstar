#!/bin/bash
# usage: scancheck.sh COMP(sway|hypr) KIND(shm|udmabuf|gbm|vkgrid) fs(0|1)
export XDG_RUNTIME_DIR=/tmp/mvk-run WAYLAND_DISPLAY=wayland-1
D=$(cd "$(dirname "$0")" && pwd)
case $2 in
  vkgrid) setsid $D/vkgrid/vkgrid scroll ;;
  shm) XDG_CONFIG_HOME=$D/config/adwaita setsid $D/bin-udmabuf/monstar -e python3 $D/scroll60-short.py 60 ;;
  udmabuf) MONSTAR_UDMABUF=1 XDG_CONFIG_HOME=$D/config/adwaita setsid $D/bin-udmabuf/monstar -e python3 $D/scroll60-short.py 60 ;;
  gbm) MONSTAR_GBM=1 XDG_CONFIG_HOME=$D/config/adwaita setsid $D/bin-udmabuf/monstar -e python3 $D/scroll60-short.py 60 ;;
esac > /tmp/mvk-term.log 2>&1 < /dev/null &
P=monstar; [ $2 = vkgrid ] && P=vkgrid
sleep 1.5
if [ "$3" = 1 ]; then
  if [ $1 = sway ]; then SWAYSOCK=$(ls /tmp/mvk-run/sway-ipc.*) swaymsg "[pid=$(pgrep -x $P)] fullscreen enable" >/dev/null
  else HYPRLAND_INSTANCE_SIGNATURE=$(ls /tmp/mvk-run/hypr | head -1) hyprctl dispatch 'hl.dsp.window.fullscreen()' >/dev/null; fi
  sleep 1
fi
[ $2 = vkgrid ] && kill -USR1 $(pgrep -x vkgrid)
sleep 1.5
for i in $(seq 20); do grep -A16 'plane\[206\]' /sys/kernel/debug/dri/1/state | grep -E "fb=|modifier=" | tr -d '\t' | tr '\n' ' '; echo; sleep 0.011; done | sort | uniq -c
