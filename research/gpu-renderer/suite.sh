#!/bin/bash
# usage: suite.sh LABEL PROCNAME "TERMINAL-CMD-PREFIX (takes -e style args)" [workloads...]
LABEL=$1; PROC=$2; CMD=$3; shift 3
WL=${@:-idle scroll60 flood latency}
export XDG_RUNTIME_DIR=/tmp/mvk-run WAYLAND_DISPLAY=wayland-1
D=$(cd "$(dirname "$0")" && pwd)
OUT=$D/results/runs.jsonl
for wl in $WL; do
  case $wl in
    idle|latency) args="sleep 1000" ;;
    scroll60) args="python3 $D/scroll60.py 60" ;;
    flood) args="$D/flood.sh" ;;
  esac
  [ $wl = latency ] && args="bash --norc"
  setsid $CMD $args > /tmp/mvk-term.log 2>&1 < /dev/null &
  sleep 3
  if [ $wl = latency ]; then
    python3 $D/latency.py 100 $D/results/lat-$LABEL.json | sed "s/^/$LABEL latency /"
  else
    python3 $D/measure.py "$LABEL/$wl" 10 $OUT $PROC,sway
  fi
  pkill -x $PROC; sleep 1
done
