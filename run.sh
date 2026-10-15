#!/bin/bash
# Launch opt-tab (Option+Tab window switcher).
cd "$(dirname "$0")"
# Ensure Homebrew is on PATH (SSH / non-login shells don't source it)
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# 1. Build if the binary is missing (it's gitignored)
if [ ! -x ./opt-tab ]; then
  echo "building opt-tab (first run)..."
  swiftc -O -o opt-tab opt-tab.swift || { echo "BUILD FAILED (try: sudo xcodebuild -license accept)"; exit 1; }
fi

# 2. Already running? (consistent check for tmux or background launches)
if pgrep -f './opt-tab' >/dev/null 2>&1; then
  echo "already running (pid $(pgrep -f './opt-tab' | head -1))"; exit 0
fi

# 3. Launch: prefer a persistent tmux session (attach to view/stop), else background
if command -v tmux >/dev/null 2>&1; then
  tmux new-session -d -s opt-tab "./opt-tab"
  sleep 1
  tmux has-session -t opt-tab 2>/dev/null && echo "started (tmux: opt-tab) — attach: tmux attach -t opt-tab" || echo "FAILED to start"
else
  echo "tmux not found — running in background (log: opt-tab.log)"
  nohup ./opt-tab > opt-tab.log 2>&1 &
  sleep 1
  kill -0 $! 2>/dev/null && echo "started (pid $!)" || echo "FAILED to start (see opt-tab.log)"
fi
