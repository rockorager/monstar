#!/bin/bash
export XDG_RUNTIME_DIR=/tmp/mvk-run WAYLAND_DISPLAY=wayland-1 SWAYSOCK=$(ls /tmp/mvk-run/sway-ipc.*)
D=$(cd "$(dirname "$0")" && pwd); M=${MONSTAR:-$D/../../zig-out/bin/monstar}
for r in 1 2 3; do for k in shm udmabuf vkgrid; do
  case $k in
    shm) XDG_CONFIG_HOME=$D/config/adwaita setsid $M -e python3 $D/scroll60-short.py 60 ;;
    udmabuf) MONSTAR_UDMABUF=1 XDG_CONFIG_HOME=$D/config/adwaita setsid $M -e python3 $D/scroll60-short.py 60 ;;
    vkgrid) setsid $D/vkgrid/vkgrid scroll ;;
  esac > /tmp/mvk-term.log 2>&1 < /dev/null &
  P=monstar; [ $k = vkgrid ] && P=vkgrid
  sleep 1.5; swaymsg "[pid=$(pgrep -x $P)] fullscreen enable" >/dev/null; sleep 1
  [ $k = vkgrid ] && kill -USR1 $(pgrep -x $P); sleep 2
  echo "$k planes-in-scanout-fb: $(grep -A30 'plane\[206\]' /sys/kernel/debug/dri/1/state | sed -n 1,30p | grep -c 'pitch\[')"
  python3 $D/measure.py "gles2-fullscreen/$k/scroll60-short" 10 $D/results/suite.jsonl $P,sway
  kill $(pgrep -x $P); sleep 1
done; done
