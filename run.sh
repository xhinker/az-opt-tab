#!/bin/bash
# Launch opt-tab (Option+Tab window switcher) in a persistent tmux session.
cd "$(dirname "$0")"
tmux has-session -t opt-tab 2>/dev/null && { echo "already running (tmux: opt-tab)"; exit 0; }
tmux new-session -d -s opt-tab "./opt-tab"
sleep 1
tmux has-session -t opt-tab 2>/dev/null && echo "started (tmux session: opt-tab)" || echo "FAILED to start"
