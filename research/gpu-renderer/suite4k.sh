#!/bin/bash
# Headless 4K@120: scroll 120 lines/s. LABEL KIND REPS
LABEL=$1; KIND=$2; REPS=${3:-2}
export XDG_RUNTIME_DIR=/tmp/mvk-run WAYLAND_DISPLAY=wayland-1
D=$(cd "$(dirname "$0")" && pwd); M=${MONSTAR:-$D/../../zig-out/bin/monstar}
for r in $(seq $REPS); do
  case $KIND in
    vkgrid) setsid $D/vkgrid/vkgrid scroll ;;
    shm) XDG_CONFIG_HOME=$D/config/adwaita setsid $M -e python3 $D/scroll60-short.py 120 ;;
    udmabuf) MONSTAR_UDMABUF=1 XDG_CONFIG_HOME=$D/config/adwaita setsid $M -e python3 $D/scroll60-short.py 120 ;;
  esac > /tmp/mvk-term.log 2>&1 < /dev/null &
  sleep 3
  P=monstar; [ $KIND = vkgrid ] && P=vkgrid
  perf stat -x, -e syscalls:sys_enter_sendmsg -p $(pgrep -x $P) -- sleep 10 2> /tmp/mvk-perfstat.txt &
  PP=$!
  python3 $D/measure.py "$LABEL/$KIND/scroll120" 10 $D/results/suite4k.jsonl $P,sway
  wait $PP; sleep 0.3
  echo "  client sendmsg/s: $(awk -F, '{printf "%.1f", $1/10}' /tmp/mvk-perfstat.txt)"
  pkill -x $P; sleep 1
done
