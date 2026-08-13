#!/bin/bash
# Emit one event per BLFS package step, on failure, and once when the build ends.
#   wsl -d lfs-host -u root -- bash /root/lfs/watch-blfs.sh
LOG=/mnt/lfs/sources/blfs/build.log

last_step=""
misses=0

while true; do
    if [ -f "$LOG" ]; then
        step=$(grep -oE '^##### .* #####$' "$LOG" | tail -1 | tr -d '#' | xargs || true)
        if [ -n "$step" ] && [ "$step" != "$last_step" ]; then
            echo "[$(date +%H:%M)] building: $step"
            last_step=$step
        fi
        if grep -qE 'FATAL|^make(\[[0-9]+\])?: \*\*\*|Error [0-9]+$|ERROR:' "$LOG"; then
            echo "[$(date +%H:%M)] BLFS BUILD FAILURE during '$step':"
            grep -E 'FATAL|^make(\[[0-9]+\])?: \*\*\*|Error [0-9]+$|ERROR:' "$LOG" | tail -5
            exit 1
        fi
    fi

    if ! pgrep -f '11-blfs-build.sh' > /dev/null 2>&1; then
        misses=$(( misses + 1 ))
        if [ "$misses" -ge 2 ]; then
            echo "[$(date +%H:%M)] BLFS BUILD ENDED. Last lines:"
            tail -14 "$LOG" 2>/dev/null
            exit 0
        fi
    else
        misses=0
    fi
    sleep 30
done
