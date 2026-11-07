#!/bin/bash
# usage: lat-interleave.sh LABEL ROUNDS N
export XDG_RUNTIME_DIR=/tmp/mvk-run WAYLAND_DISPLAY=wayland-1
D=$(cd "$(dirname "$0")" && pwd); M=${MONSTAR:-$D/../../zig-out/bin/monstar}
for r in $(seq $2); do for k in shm udmabuf vkgrid; do
  case $k in
    shm) XDG_CONFIG_HOME=$D/config/adwaita setsid $M -e bash --norc ;;
    udmabuf) MONSTAR_UDMABUF=1 XDG_CONFIG_HOME=$D/config/adwaita setsid $M -e bash --norc ;;
    vkgrid) setsid $D/vkgrid/vkgrid idle ;;
  esac > /tmp/mvk-term.log 2>&1 < /dev/null &
  sleep 2.5
  python3 $D/latency.py $3 $D/results/latx-$1-$k-$r.json | sed "s#^#$1/$k/$r #"
  pkill -x monstar; pkill -x vkgrid; sleep 1
done; done
