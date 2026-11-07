#!/bin/bash
# Same finite scroll in both builds; screenshots must match exactly.
export XDG_RUNTIME_DIR=/tmp/mvk-run WAYLAND_DISPLAY=wayland-1
D=$(cd "$(dirname "$0")" && pwd); A=${SHOTS:-/tmp}
for case in nimbus:text-short.txt adwaita:text-accent.txt; do font=${case%%:*}; txt=${case#*:}
  cfg=$D/config/default; [ $font = adwaita ] && cfg=$D/config/adwaita
  for bin in before after; do
    XDG_CONFIG_HOME=$cfg setsid $D/bin-$bin/monstar -e python3 $D/scroll-finite.py $D/$txt 400 > /dev/null 2>&1 < /dev/null &
    sleep 9; grim $A/pix-$font-$bin.png; pkill -x monstar; sleep 1
  done
  cmp -s $A/pix-$font-before.png $A/pix-$font-after.png && echo "$font: identical" || python3 -c "print('$font: differ')"
done
