#!/bin/bash
pkill -x sway; sleep 1; pkill -x seatd; sleep 0.5; chvt 1; pgrep -a 'sway|seatd' || echo clean
