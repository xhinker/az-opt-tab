# az-opt-tab

A Windows-11-style **per-window** switcher for macOS. Hold **Option** and press **Tab** to
cycle through individual *windows* (most-recently-used first), hold to auto-cycle, and release
**Option** to bring the selected window to the front.

Unlike the built-in `Cmd+Tab` (which switches *apps*), az-opt-tab switches **windows** —
Chrome tab A → VS Code window B → iTerm pane C. It covers **all Spaces**, so windows on other
desktops are included, and it shows a **live thumbnail** of every window.

## Features

- **Per-window** switching (not per-app), most-recently-used order like Windows Alt+Tab
- **All Spaces** — windows on other desktops are listed and switchable (macOS follows to its Space)
- **Hold to auto-cycle** — hold `Option+Tab` to advance down, `Option+Shift+Tab` to advance up (throttled to a comfortable ~10/sec)
- **Live window thumbnails** (ScreenCaptureKit), with a RAM cache so reopens are instant
- **Multi-monitor** — one overlay per screen, all in sync
- **Mouse** — scroll to navigate, click a row to jump straight to that window
- **Fast** — 0ms to open, ~15–38ms to commit (window on screen)

## Requirements

- macOS (built and tested on macOS 26 / Darwin 25). Uses only public APIs plus one long-stable
  private bridge (`_AXUIElementGetWindow`, the same one yabai / alt-tab-macos use).
- **Accessibility** permission (window activation + key monitoring).
- **Screen Recording** permission (live thumbnails). Without it, rows fall back to app icons.

Both are granted in **System Settings → Privacy & Security**. When launched from a terminal the
app inherits the terminal's grants; otherwise it prompts on startup.

## Build & run

```bash
./run.sh                 # builds (if needed) and runs in a persistent tmux session "opt-tab"
tmux attach -t opt-tab   # watch its log
tmux kill-session -t opt-tab   # stop

# or build/run directly:
swiftc -O -o opt-tab opt-tab.swift
./opt-tab
```

## Usage

| Action | Effect |
|---|---|
| `Option+Tab` (quick tap) | Open the switcher on the most recent *other* window |
| **Hold** `Option+Tab` | Auto-advance to the next window (down) |
| **Hold** `Option+Shift+Tab` | Auto-advance to the previous window (up) |
| Mouse scroll on the overlay | Next (down) / previous (up) |
| Mouse click on a row | Jump straight to that window |
| Release `Option` | Bring the highlighted window to the front |

The overlay shows all windows as a vertical list centered on the selection: **sequence number**
(1 = most recent) + **app icon** + **live thumbnail** + **window title** (falls back to app name),
with `↑`/`↓` arrows when there are more windows and an `n / total` counter.

## How it works

| Concern | Approach |
|---|---|
| Global hotkey + auto-repeat | A `CGEventTap` on the Tab key sees the system's key auto-repeat, so **holding** Tab fires repeated events → auto-advance (throttled to ~10/sec) |
| Window inventory (all Spaces) | Per-app Accessibility `kAXWindowsAttribute` over `NSWorkspace.runningApplications` |
| MRU ordering | AX `kAXFocusedWindowAttribute` polled at 300ms; reorders only on focus change so the list is stable while navigating |
| Window activation | `NSRunningApplication.activate()` + `kAXRaiseAction` (the raise alone makes the window key+focused) |
| wid ↔ AX element bridge | `_AXUIElementGetWindow` (private, stable 15+ years) |
| Option-release (commit) | `NSEvent` `.flagsChanged` monitor + a 300ms tick fallback (`CGEvent(source: nil).flags`) |
| Live thumbnails | One low-res `SCStream` per visible window (1 fps) → frames converted on background queues into a RAM cache; a slow 500ms timer applies them to the UI and **pauses while you're navigating** so Tab stays at top priority |
| No-flicker navigation | Persistent row slots updated in place; only changed rows redraw |
| Multi-monitor | One overlay panel per `NSScreen`, all driven by a shared state machine |

### Performance notes

- **0ms to open** — the window inventory is warmed at launch and refreshed in the background
  (~2s), never rebuilt on the Tab path.
- **~15–38ms to commit** — the residual time is the window server raising the window.
- **Instant reopen** — the last thumbnail per window is kept in RAM across open/close.
- **Decoupled threads** — thumbnail capture/conversion runs on background queues; the UI apply
  timer yields while you're actively Tabbing, so navigation never waits on thumbnails.

## Files

- `opt-tab.swift` — the whole program (~750 lines, single file)
- `run.sh` — tmux launcher

## Credits

Modeled on [lwouis/alt-tab-macos](https://github.com/lwouis/alt-tab-macos) (the reference
Windows-style switcher for macOS). This project keeps the same semantics but is a compact,
single-file implementation on public APIs.

## License

MIT — see [LICENSE](LICENSE).
