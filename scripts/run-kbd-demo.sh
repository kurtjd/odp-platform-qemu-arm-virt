#!/usr/bin/env bash
# One-command launcher for the virtual-keyboard demo.
#
# SPDX-License-Identifier: MIT
#
# Layout:
#   - UEFI + Windows (GTK window) is booted in the BACKGROUND; its logs are
#     discarded (we only care about the window).
#   - A tmux session with two panes is opened in this terminal:
#       * left  pane: EC firmware logs (`make run_ec`, tee'd to the log file)
#       * right pane: picocom attached to the EC UART0 — TYPE HERE.
#
# Quit: in the picocom pane press Ctrl-A Ctrl-X, or kill the tmux session with
# Ctrl-b & . Either way the background OS QEMU is torn down on exit.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

command -v tmux >/dev/null 2>&1 ||
    { echo "error: tmux not installed (apt-get install tmux)" >&2; exit 1; }

LOG="${EC_RUN_LOG:-/tmp/ec-run.log}"
BAUD="${EC_BAUD:-115200}"
OS_LOG="${OS_LOG:-/tmp/run-os.log}"
SESSION="kbd-demo"
rm -f "$LOG"

# Drop any lingering session from a previous run.
tmux kill-session -t "$SESSION" 2>/dev/null || true

# Boot UEFI + Windows (GTK window) in the background; logs go to a file we ignore.
setsid bash -c "make run_os QEMU_DISPLAY=gtk >\"$OS_LOG\" 2>&1" &
OS_PID=$!

cleanup() {
    echo "Tearing down background OS QEMU..."
    kill -- -"$OS_PID" 2>/dev/null || kill "$OS_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Pane 0 (left): picocom, discovered from the EC log — TYPE HERE.
tmux new-session -d -s "$SESSION" -n demo \
    "cd '$REPO_ROOT'; scripts/ec-picocom.sh '$LOG' '$BAUD'; echo; echo '[picocom exited — press Enter to close]'; read"

# Pane 1 (right): EC firmware logs.
tmux split-window -h -t "$SESSION":demo \
    "cd '$REPO_ROOT'; make run_ec 2>&1 | tee '$LOG'; echo; echo '[EC exited — press Enter to close]'; read"

tmux set-option -t "$SESSION" mouse on
tmux select-pane -t "$SESSION":demo.0   # focus the picocom pane so you can type
tmux attach-session -t "$SESSION"
