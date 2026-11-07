#!/bin/bash
export XDG_RUNTIME_DIR=/tmp/mvk-run WAYLAND_DISPLAY=wayland-1
D=$(cd "$(dirname "$0")" && pwd); OUT=$D/results/overhang-ab.jsonl
for r in 1 2 3; do for wl in nimbus:scroll60 nimbus:scroll60-short adwaita:scroll60-accent adwaita:scroll60-short; do for bin in before after; do
  font=${wl%%:*}; w=${wl#*:}; cfg=$D/config/default; [ $font = adwaita ] && cfg=$D/config/adwaita
  XDG_CONFIG_HOME=$cfg setsid $D/bin-$bin/monstar -e python3 $D/$w.py 60 > /tmp/mvk-term.log 2>&1 < /dev/null &
  sleep 3
  python3 $D/measure.py "$bin/$font/$w" 10 $OUT monstar,sway
  pkill -x monstar; sleep 1
done; done; done
