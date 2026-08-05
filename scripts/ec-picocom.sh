#!/usr/bin/env bash
# Wait for the EC QEMU's `-serial pty` PTY to be reported in the run_ec log,
# then attach picocom so you can type into the EC's UART0 (the keyboard demo).
#
# SPDX-License-Identifier: MIT
#
# The EC launcher (mod/ec/platform/dev-qemu/qemu-ec.sh) runs QEMU with
# `-serial pty`, which allocates a fresh /dev/pts/N at startup and prints
# "char device redirected to /dev/pts/N (label serial0)". That path isn't known
# until runtime, so this script polls the captured run_ec output for it, waits
# for the device node to exist, then execs picocom on it.
#
# Usage: ec-picocom.sh [log-file] [baud] [timeout-secs]

set -euo pipefail

LOG="${1:-/tmp/ec-run.log}"
BAUD="${2:-115200}"
TIMEOUT_S="${3:-120}"

command -v picocom >/dev/null 2>&1 ||
    { echo "error: picocom not installed (apt-get install picocom)" >&2; exit 1; }

echo "Waiting for EC UART PTY (scanning $LOG)..."
pts=""
deadline=$(( $(date +%s) + TIMEOUT_S ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    if [ -f "$LOG" ]; then
        # Take the most recent /dev/pts/N the launcher reported and make sure
        # the node actually exists (guards against a stale path from a prior run).
        cand=$(grep -ahoE '/dev/pts/[0-9]+' "$LOG" 2>/dev/null | tail -1 || true)
        if [ -n "$cand" ] && [ -e "$cand" ]; then
            pts="$cand"
            break
        fi
    fi
    sleep 0.2
done

if [ -z "$pts" ]; then
    echo "error: timed out after ${TIMEOUT_S}s waiting for the EC UART PTY" >&2
    echo "       is the 'run_ec (logged)' task running and writing to $LOG?" >&2
    exit 1
fi

echo "Attaching picocom to $pts at ${BAUD} baud."
echo "Type here to send keystrokes to Windows over the virtual I2C keyboard."
echo "Exit picocom with: Ctrl-A Ctrl-X"
exec picocom --echo -b "$BAUD" "$pts"
