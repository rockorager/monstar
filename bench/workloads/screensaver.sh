#!/bin/sh
# The Omarchy screensaver loop (omarchy-screensaver at Omarchy 7644b56),
# with one fixed tte effect instead of --random-effect and without the
# Hyprland focus and keypress checks.
# usage: screensaver.sh LOGO EFFECT   (PYTHONPATH must contain tte)
logo=$1
effect=$2
printf '\033]11;rgb:00/00/00\007'
stty -echo 2>/dev/null
while true; do
  python3 -m terminaltexteffects -i "$logo" \
    --frame-rate 120 --canvas-width 0 --canvas-height 0 --reuse-canvas --anchor-canvas c --anchor-text c \
    --no-eol --no-restore-cursor "$effect" || exit 1
done
