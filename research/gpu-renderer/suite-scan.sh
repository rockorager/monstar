#!/bin/bash
# usage: suite-scan.sh COMP(sway|hypr) LAYOUT(comp|fs) REPS
COMP=$1; LAYOUT=$2; REPS=${3:-3}
export XDG_RUNTIME_DIR=/tmp/mvk-run WAYLAND_DISPLAY=wayland-1
D=$(cd "$(dirname "$0")" && pwd); OUT=$D/results/scan.jsonl
CP=sway; [ $COMP = hypr ] && CP=Hyprland
for r in $(seq $REPS); do for k in shm udmabuf gbm vkgrid; do
  case $k in
    vkgrid) setsid $D/vkgrid/vkgrid scroll ;;
    shm) XDG_CONFIG_HOME=$D/config/adwaita setsid $D/bin-udmabuf/monstar -e python3 $D/scroll60-short.py 60 ;;
    udmabuf) MONSTAR_UDMABUF=1 XDG_CONFIG_HOME=$D/config/adwaita setsid $D/bin-udmabuf/monstar -e python3 $D/scroll60-short.py 60 ;;
    gbm) MONSTAR_GBM=1 XDG_CONFIG_HOME=$D/config/adwaita setsid $D/bin-udmabuf/monstar -e python3 $D/scroll60-short.py 60 ;;
  esac > /tmp/mvk-term.log 2>&1 < /dev/null &
  P=monstar; [ $k = vkgrid ] && P=vkgrid
  sleep 1.5
  if [ $LAYOUT = fs ]; then
    if [ $COMP = sway ]; then SWAYSOCK=$(ls /tmp/mvk-run/sway-ipc.*) swaymsg "[pid=$(pgrep -x $P)] fullscreen enable" >/dev/null
    else HYPRLAND_INSTANCE_SIGNATURE=$(ls /tmp/mvk-run/hypr | head -1) hyprctl dispatch 'hl.dsp.window.fullscreen()' >/dev/null; fi
    sleep 1
    [ $k = vkgrid ] && kill -USR1 $(pgrep -x vkgrid)
  fi
  sleep 2
  mod=$(grep -A16 'plane\[206\]' /sys/kernel/debug/dri/1/state | grep -o "modifier=0x[0-9a-f]*")
  [ "$mod" = "modifier=0x0" ] && sc=1 || sc=0
  python3 $D/measure.py "$COMP-$LAYOUT/$k scanout=$sc" 10 $OUT $P,$CP
  pkill -x $P; sleep 1
done; done
