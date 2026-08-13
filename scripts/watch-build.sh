#!/bin/bash
# Emit one progress line per chapter transition, every 8 completed targets, on any
# build failure, and once when the build process ends. Each echoed line is an event.
#
#   wsl -d lfs-host -u root -- bash /root/lfs/watch-build.sh
#
# Progress is counted from jhalfs' per-target stamp files rather than from the log,
# because the log is rotated on every resume while the stamps are cumulative --
# a log-derived count reads 0/130 after a restart even with most of the build done.
JH=/mnt/lfs/jhalfs
LOG=$JH/build.log
TOTAL=130

# Strip jhalfs' colour escapes and stray pty NULs before matching.
clean() { sed -r 's/\x1B\[[0-9;]*[a-zA-Z]//g; s/\x00//g' "$LOG" 2>/dev/null; }
stamps() { ls "$JH" 2>/dev/null | grep -cE '^[0-9]{3,4}-'; }
# Match the launcher's runner script, not `make` itself: sub-makes come and go, and
# the runner is the one process that lives exactly as long as the build.
alive() { pgrep -f 'jhalfs/run-make.sh' > /dev/null 2>&1; }

last_ch=""
last_done=$(stamps)
last_errcount=$(clean | grep -cE 'make: \*\*\*|FATAL|\*\*\* \[')
misses=0

while true; do
    cur=$(clean | grep -oE 'Building target [0-9]+' | tail -1 | grep -oE '[0-9]+$')

    if [ -n "$cur" ]; then
        ch=$(( cur / 100 ))
        if [ "$ch" != "$last_ch" ]; then
            echo "[$(date +%H:%M)] chapter $ch started (target $cur)"
            last_ch=$ch
        fi
    fi

    done_n=$(stamps)
    if [ $(( done_n - last_done )) -ge 8 ]; then
        echo "[$(date +%H:%M)] progress: $done_n/$TOTAL targets complete (building $cur)"
        last_done=$done_n
    fi

    errcount=$(clean | grep -cE 'make: \*\*\*|FATAL|\*\*\* \[')
    if [ "$errcount" -gt "$last_errcount" ]; then
        echo "[$(date +%H:%M)] BUILD FAILURE while building $cur ($done_n/$TOTAL done):"
        clean | grep -E 'make: \*\*\*|FATAL|\*\*\* \[' | tail -5
        exit 1
    fi

    # Require two consecutive misses so a transient pgrep hiccup is not read as "ended".
    if alive; then
        misses=0
    else
        misses=$(( misses + 1 ))
        if [ "$misses" -ge 2 ]; then
            echo "[$(date +%H:%M)] BUILD ENDED: $done_n/$TOTAL targets completed. Last lines:"
            clean | tail -8
            exit 0
        fi
    fi

    sleep 60
done
