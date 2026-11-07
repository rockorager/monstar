#!/bin/bash
# usage: suite2.sh LABEL KIND REPS   KIND = shm | udmabuf | vkgrid | shm-nimbus
LABEL=$1; KIND=$2; REPS=${3:-3}
export XDG_RUNTIME_DIR=/tmp/mvk-run WAYLAND_DISPLAY=wayland-1
D=$(cd "$(dirname "$0")" && pwd); OUT=$D/results/suite.jsonl
M=${MONSTAR:-$D/../../zig-out/bin/monstar}
launch() { # workload
  case $KIND in
    vkgrid) case $1 in scroll60*) a=scroll;; *) a=idle;; esac; setsid $D/vkgrid/vkgrid $a ;;
    *) case $1 in idle) a="sleep 1000";; latency) a="bash --norc";; scroll60) a="python3 $D/scroll60.py 60";;
                  scroll60-short) a="python3 $D/scroll60-short.py 60";; flood) a="$D/flood.sh";; esac
       if [ $KIND = shm-nimbus ]; then cfg=$D/config/default; else cfg=$D/config/adwaita; fi
       if [ $KIND = udmabuf ]; then export MONSTAR_UDMABUF=1; else unset MONSTAR_UDMABUF; fi
       XDG_CONFIG_HOME=$cfg setsid $M -e $a ;;
  esac > /tmp/mvk-term.log 2>&1 < /dev/null &
}
PROC=monstar; [ $KIND = vkgrid ] && PROC=vkgrid
WLS="idle scroll60 scroll60-short flood"; [ $KIND = vkgrid ] && WLS="idle scroll60"
for r in $(seq $REPS); do for wl in $WLS; do
  launch $wl; sleep 3
  python3 $D/measure.py "$LABEL/$KIND/$wl" 10 $OUT $PROC,sway
  pkill -x $PROC; sleep 1
done; done
launch latency; sleep 3
python3 $D/latency.py 120 $D/results/lat-$LABEL-$KIND.json | sed "s#^#$LABEL/$KIND latency #"
pkill -x $PROC; sleep 1
