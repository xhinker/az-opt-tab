// opt-tab — Windows-11-style window switcher for macOS
//
// Option+Tab        → next window (MRU order, latest first)
// Option+Shift+Tab  → previous window
// Release Option    → commit (selected window comes to front)
//
// The overlay shows ALL windows as a horizontal icon strip (viewport of 11
// centered on the selection, like Windows 11's switcher). Covers all Spaces.
//
// Reference: lwouis/alt-tab-macos (16.4k★, GPL-3.0).
//
// Requires: Accessibility permission (window activation + flagsChanged monitor).

import Cocoa
import Carbon
import ApplicationServices
import ScreenCaptureKit

// MARK: - Private bridge (element → window id; no public equivalent exists)
@_silgen_name("_AXUIElementGetWindow")
func axUIElementGetWindow(_ element: AXUIElement, _ wid: inout CGWindowID) -> AXError

// MARK: - Logging
func log(_ msg: String) {
    let ts = Date().formatted(.iso8601)
    FileHandle.standardError.write("[\(ts)] \(msg)\n".data(using: .utf8)!)
}

// MARK: - Window model
struct Win {
    let pid: pid_t
    let wid: CGWindowID
    var title: String
    var appName: String
    var icon: NSImage?
}

// MARK: - MRU (most-recently-used first, like Windows 11 Alt+Tab)
final class MRU {
    private(set) var list: [(pid: pid_t, wid: CGWindowID)] = []

    func moveToFront(_ pid: pid_t, _ wid: CGWindowID) {
        let idx = list.firstIndex { $0.wid == wid }
        if let i = idx {
            if i == 0 { return }
            list.remove(at: i)
            list.insert((pid, wid), at: 0)
        } else {
            list.insert((pid, wid), at: 0)
        }
    }

    func prune(live: Set<CGWindowID>, newWindows: [(pid: pid_t, wid: CGWindowID)]) {
        list.removeAll { !live.contains($0.wid) }
        let tracked = Set(list.map { $0.wid })
        for w in newWindows where !tracked.contains(w.wid) {
            list.append(w)
        }
    }
}

// MARK: - AX helpers
func axCopy(_ element: AXUIElement, _ attr: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success ? value : nil
}

func axCopyElement(_ element: AXUIElement, _ attr: String) -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success,
          let v = value, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
    return (v as! AXUIElement)
}

func focusedWindowID(pid: pid_t) -> CGWindowID? {
    let appEl = AXUIElementCreateApplication(pid)
    guard let focused = axCopyElement(appEl, kAXFocusedWindowAttribute) else { return nil }
    var wid: CGWindowID = 0
    return axUIElementGetWindow(focused, &wid) == .success ? wid : nil
}

// MARK: - Window inventory: ALL windows of all apps (every Space), via per-app AX
// App icons are stable — cache them so the periodic background refresh is cheap.
var iconCache: [pid_t: NSImage] = [:]
// AX window elements cached by CGWindowID — lets activateWindow raise a window
// without the slow per-window id-lookup loop.
var axWindowCache: [CGWindowID: AXUIElement] = [:]

func allWindows() -> [Win] {
    let myPid = ProcessInfo.processInfo.processIdentifier
    var wins: [Win] = []
    var seen = Set<CGWindowID>()
    for app in NSWorkspace.shared.runningApplications {
        guard app.processIdentifier != myPid, app.activationPolicy == .regular else { continue }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        guard let windows = axCopy(appEl, kAXWindowsAttribute) as? [AXUIElement] else { continue }
        let icon = iconCache[app.processIdentifier] ?? {
            let img = app.icon
            iconCache[app.processIdentifier] = img
            return img
        }()
        for w in windows {
            var wid: CGWindowID = 0
            guard axUIElementGetWindow(w, &wid) == .success, seen.insert(wid).inserted else { continue }
            axWindowCache[wid] = w
            let title = (axCopy(w, kAXTitleAttribute) as? String) ?? ""
            wins.append(Win(pid: app.processIdentifier, wid: wid, title: title,
                            appName: app.localizedName ?? "?", icon: icon))
        }
    }
    return wins
}

func activateWindow(pid: pid_t, wid: CGWindowID) {
    // 1) bring the owning app to the front — NSRunningApplication.activate() is
    //    ~1-2ms (vs 49ms for the AX kAXFrontmost round-trip).
    NSRunningApplication(processIdentifier: pid)?.activate()
    // 2) raise the specific window. kAXRaiseAction ALONE makes the window key +
    //    focused (verified: the raised window becomes the app's focused window),
    //    so we skip the separate kAXMain/kAXFocused round-trips (~30-50ms saved).
    if let w = axWindowCache[wid] {
        AXUIElementPerformAction(w, kAXRaiseAction as CFString)
        return
    }
    // Fallback: cache miss (window appeared since the last background refresh).
    let appEl = AXUIElementCreateApplication(pid)
    if let windows = axCopy(appEl, kAXWindowsAttribute) as? [AXUIElement] {
        for w in windows {
            var wID: CGWindowID = 0
            if axUIElementGetWindow(w, &wID) == .success, wID == wid {
                axWindowCache[wid] = w
                AXUIElementPerformAction(w, kAXRaiseAction as CFString)
                return
            }
        }
    }
    log("activate: wid \(wid) not found (app frontmost only)")
}

// MARK: - Current physical Option state (synchronous, no event-queue lag)
func optionDownNow() -> Bool {
    guard let e = CGEvent(source: nil) else { return false }
    return e.flags.contains(.maskAlternate)
}

// MARK: - Live per-window thumbnail streams (ScreenCaptureKit SCStream)
// One low-res SCStream per window → always-fresh thumbnails, no capture spikes.
final class StreamOutput: NSObject, SCStreamOutput {
    let wid: CGWindowID
    let onFrame: (CGWindowID, CMSampleBuffer) -> Void
    private var lastUI: TimeInterval = 0
    private let uiThrottle: TimeInterval = 0.2   // max 5 UI updates/sec per window
    init(wid: CGWindowID, onFrame: @escaping (CGWindowID, CMSampleBuffer) -> Void) {
        self.wid = wid
        self.onFrame = onFrame
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        let now = Date().timeIntervalSince1970
        if now - lastUI < uiThrottle { return }
        lastUI = now
        onFrame(wid, sb)
    }
}

final class ThumbnailStreamer {
    static let shared = ThumbnailStreamer()

    private struct Entry { let stream: SCStream; let output: StreamOutput }
    private var entries: [CGWindowID: Entry] = [:]
    private let ciContext = CIContext()
    /// Latest converted frame per window — written on stream queues, read on main.
    /// Kept across open/close (RAM cache) so reopens show thumbnails instantly.
    private var latest: [CGWindowID: NSImage] = [:]
    private let lock = NSLock()

    /// Start streams for windows in `keep`; stop the rest.
    func sync(keep: [Win], content: SCShareableContent) {
        let keepWids = Set(keep.map { $0.wid })
        for (wid, entry) in entries where !keepWids.contains(wid) {
            Task { _ = try? await entry.stream.stopCapture() }
            entries[wid] = nil
        }
        for win in keep where entries[win.wid] == nil {
            guard let scWindow = content.windows.first(where: { $0.windowID == win.wid }) else { continue }
            startStream(for: win.wid, scWindow: scWindow)
        }
    }

    func stopAll() {
        for (_, entry) in entries {
            Task { _ = try? await entry.stream.stopCapture() }
        }
        entries.removeAll()
        // Keep `latest` (the RAM cache) so the next open shows thumbnails instantly
        // without re-capturing.
    }

    /// Drop cached thumbnails for windows that no longer exist.
    func prune(live: Set<CGWindowID>) {
        lock.lock()
        for wid in latest.keys where !live.contains(wid) { latest[wid] = nil }
        lock.unlock()
    }

    private func startStream(for wid: CGWindowID, scWindow: SCWindow) {
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = SCStreamConfiguration()
        config.width = 320
        config.height = max(1, Int(320 * scWindow.frame.height / max(scWindow.frame.width, 1)))
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)    // 1 fps (switcher: low load, RAM-cached)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        let output = StreamOutput(wid: wid) { [weak self] w, sb in
            self?.handleFrame(wid: w, sb: sb)
        }
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        entries[wid] = Entry(stream: stream, output: output)
        Task { @MainActor in
            do {
                try await stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: nil)
                try await stream.startCapture()
            } catch {
                log("stream start failed \(wid): \(error.localizedDescription)")
                entries[wid] = nil
            }
        }
    }

    /// Runs on the stream's background queue: convert + store only. NO main-thread work here.
    private func handleFrame(wid: CGWindowID, sb: CMSampleBuffer) {
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        let ci = CIImage(cvPixelBuffer: pb)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return }
        let ns = NSImage(cgImage: cg, size: .zero)
        lock.lock()
        latest[wid] = ns
        lock.unlock()
    }

    /// Main thread: push the latest cached thumbnail for every window to the UI.
    /// Called from a low-frequency timer AND synchronously on each show(). Re-applying
    /// the same image is cheap, and it's required because update() resets slots to the
    /// app icon whenever the visible rows change during navigation.
    func applyPending(_ apply: (CGWindowID, NSImage) -> Void) {
        lock.lock()
        let snapshot = latest
        lock.unlock()
        guard !snapshot.isEmpty else { return }
        for (wid, img) in snapshot {
            apply(wid, img)
        }
    }
}

func screenCaptureAllowed() -> Bool {
    CGPreflightScreenCaptureAccess()
}

// MARK: - Window/card subclasses (mouse events)
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Card view that forwards mouse events to the panel.
final class CardView: NSVisualEffectView {
    var onMouseDown: ((NSPoint) -> Void)?     // point in card coords
    var onScroll: ((CGFloat) -> Void)?         // deltaY (px)

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        onMouseDown?(p)
    }

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event.scrollingDeltaY)
    }
}

/// Row container: accepts first mouse (window isn't key when the user clicks us)
/// and hit-tests as one unit so subviews never swallow the click.
final class RowView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        return bounds.contains(p) ? self : nil
    }
}

// MARK: - Per-screen panel (one overlay window per monitor)
// Each panel shows the same list; all panels update in sync.
final class ScreenPanel {
    static let maxVisible = 10
    static let rowH: CGFloat = 64          // reduced from 74 (shorter rows)
    static let cardW: CGFloat = 520
    static let topChrome: CGFloat = 26     // top area (count label + up arrow)
    static let bottomChrome: CGFloat = 48  // bottom area (down arrow)
    /// Card height for a given number of visible rows — auto-shrinks when there
    /// are fewer than maxVisible windows.
    static func dynamicHeight(_ visible: Int) -> CGFloat {
        topChrome + CGFloat(visible) * rowH + bottomChrome
    }

    let screen: NSScreen
    let window: OverlayWindow
    let card: CardView

    private struct Slot {
        let row: RowView
        let bg: NSView
        let num: NSTextField
        let appIcon: NSImageView
        let thumb: NSImageView
        let label: NSTextField
        var wid: CGWindowID? = nil
        var selected = false
    }
    private var slots: [Slot] = []
    private var rowIndices: [Int] = []
    private var pendingScroll: CGFloat = 0
    private let upArrow = NSTextField(labelWithString: "↑")
    private let downArrow = NSTextField(labelWithString: "↓")
    private let countLabel = NSTextField(labelWithString: "")

    var onMouseDown: ((Int) -> Void)?     // absolute list index
    var onScroll: ((Int) -> Void)?

    init(screen: NSScreen) {
        self.screen = screen
        let size = NSSize(width: Self.cardW, height: Self.dynamicHeight(Self.maxVisible))
        window = OverlayWindow(contentRect: NSRect(origin: .zero, size: size),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        card = CardView()
        card.frame = NSRect(origin: .zero, size: size)
        card.material = .hudWindow
        card.state = .active
        card.blendingMode = .behindWindow
        card.wantsLayer = true
        card.layer?.cornerRadius = 18
        card.layer?.masksToBounds = true

        for arrow in [upArrow, downArrow] {
            arrow.font = .systemFont(ofSize: 16, weight: .medium)
            arrow.textColor = .secondaryLabelColor
            arrow.alignment = .center
            arrow.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(arrow)
        }
        countLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        countLabel.textColor = .tertiaryLabelColor
        countLabel.alignment = .center
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(countLabel)

        NSLayoutConstraint.activate([
            countLabel.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            countLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            upArrow.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            upArrow.topAnchor.constraint(equalTo: card.topAnchor, constant: 30),
            upArrow.widthAnchor.constraint(equalToConstant: 22),
            downArrow.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            downArrow.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
            downArrow.widthAnchor.constraint(equalToConstant: 22),
        ])
        card.onMouseDown = { [weak self] p in self?.handleMouseDown(p) }
        card.onScroll = { [weak self] dy in self?.handleScroll(dy) }
        window.contentView = card
    }

    private func handleMouseDown(_ point: NSPoint) {
        for (i, slot) in slots.enumerated() where slot.row.frame.contains(point) {
            onMouseDown?(rowIndices[i])
            return
        }
    }

    private func handleScroll(_ deltaY: CGFloat) {
        pendingScroll += deltaY
        let step: CGFloat = 10
        while pendingScroll >= step {
            pendingScroll -= step
            onScroll?(+1)
        }
        while pendingScroll <= -step {
            pendingScroll += step
            onScroll?(-1)
        }
    }

    private func rebuildSlots(_ count: Int) {
        for s in slots { s.row.removeFromSuperview() }
        slots.removeAll()
        let rowH = Self.rowH
        for i in 0..<count {
            let row = RowView(frame: NSRect(x: 12, y: Self.bottomChrome + CGFloat(count - 1 - i) * rowH,
                                            width: 496, height: rowH))
            let bg = NSView(frame: NSRect(x: 0, y: 2, width: 496, height: rowH - 4))
            bg.wantsLayer = true
            bg.layer?.cornerRadius = 12
            bg.layer?.borderWidth = 0
            bg.layer?.backgroundColor = CGColor.clear

            let num = NSTextField(labelWithString: "")
            num.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular)
            num.textColor = .tertiaryLabelColor
            num.alignment = .right
            num.frame = NSRect(x: 0, y: (rowH - 20) / 2, width: 32, height: 20)

            let appIcon = NSImageView(frame: NSRect(x: 38, y: (rowH - 32) / 2, width: 32, height: 32))
            appIcon.imageScaling = .scaleProportionallyUpOrDown

            let thumb = NSImageView(frame: NSRect(x: 78, y: 3, width: 140, height: rowH - 6))
            thumb.wantsLayer = true
            thumb.layer?.cornerRadius = 7
            thumb.layer?.masksToBounds = true
            thumb.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
            thumb.imageScaling = .scaleProportionallyUpOrDown

            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 14)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            label.frame = NSRect(x: 228, y: (rowH - 18) / 2, width: 268, height: 18)

            row.addSubview(bg)
            row.addSubview(num)
            row.addSubview(appIcon)
            row.addSubview(thumb)
            row.addSubview(label)
            card.addSubview(row)
            slots.append(Slot(row: row, bg: bg, num: num, appIcon: appIcon,
                              thumb: thumb, label: label))
        }
    }

    private func applySelection(_ slot: inout Slot, selected: Bool) {
        guard slot.selected != selected else { return }
        slot.selected = selected
        slot.bg.layer?.borderWidth = selected ? 2 : 0
        slot.bg.layer?.backgroundColor = selected
            ? NSColor.white.withAlphaComponent(0.14).cgColor : CGColor.clear
        slot.num.font = .monospacedDigitSystemFont(ofSize: 14, weight: selected ? .semibold : .regular)
        slot.num.textColor = selected ? .labelColor : .tertiaryLabelColor
        slot.label.font = .systemFont(ofSize: 14, weight: selected ? .semibold : .regular)
        slot.label.textColor = selected ? .labelColor : .secondaryLabelColor
    }

    /// Update this panel in place. Returns the set of wids whose slot content changed.
    func update(windows: [Win], selection: Int) -> Set<CGWindowID> {
        let n = windows.count
        let visible = min(Self.maxVisible, n)
        let start = max(0, min(selection - Self.maxVisible / 2, n - visible))

        if slots.count != visible {
            rebuildSlots(visible)
        }
        let H = Self.dynamicHeight(visible)
        if abs(window.frame.height - H) > 0.5 {
            window.setContentSize(NSSize(width: Self.cardW, height: H))
        }

        var changed: Set<CGWindowID> = []
        for i in 0..<visible {
            let idx = start + i
            let win = windows[idx]
            var slot = slots[i]
            if slot.wid != win.wid {
                slot.wid = win.wid
                slot.num.stringValue = "\(idx + 1)"
                slot.appIcon.image = win.icon
                slot.thumb.image = win.icon
                slot.label.stringValue = win.title.isEmpty ? win.appName : win.title
                changed.insert(win.wid)
            }
            applySelection(&slot, selected: idx == selection)
            slots[i] = slot
        }
        rowIndices = (0..<visible).map { start + $0 }

        upArrow.isHidden = start <= 0
        downArrow.isHidden = start + visible >= n
        countLabel.stringValue = "\(selection + 1) / \(n)"

        let f = screen.frame
        window.setFrameOrigin(NSPoint(x: f.midX - Self.cardW / 2,
                                      y: f.midY - H / 2 + 20))
        window.orderFrontRegardless()
        return changed
    }

    func applyThumbnails(_ imgs: [CGWindowID: CGImage]) {
        for i in slots.indices {
            if let wid = slots[i].wid, let cg = imgs[wid] {
                slots[i].thumb.image = NSImage(cgImage: cg, size: .zero)
            }
        }
    }

    func applyThumbnail(wid: CGWindowID, image: NSImage) {
        for i in slots.indices where slots[i].wid == wid {
            slots[i].thumb.image = image
        }
    }

    func hide() {
        pendingScroll = 0
        window.orderOut(nil)
    }
}

// MARK: - Overlay: manages one panel per active monitor
final class Overlay {
    private var panels: [ScreenPanel] = []
    private var content: SCShareableContent?
    private var applyTimer: Timer?

    /// Pre-create the per-monitor panels at launch so the first Option+Tab
    /// doesn't pay the one-time view-creation cost (~200ms).
    func warmUp() {
        ensurePanels()
    }

    private func ensurePanels() {
        let screens = NSScreen.screens
        if panels.count != screens.count {
            for p in panels { p.hide() }
            panels = screens.map { ScreenPanel(screen: $0) }
            for p in panels {
                p.onMouseDown = { idx in
                    log("mouse click → row \(idx + 1)")
                    Switcher.shared.selectAndCommit(idx)
                }
                p.onScroll = { dir in
                    Switcher.shared.step(direction: dir)
                }
            }
        }
        // Thumbnails are applied on a slow, pausable timer — never in the Tab path.
        // While the user is actively navigating, the timer yields (Tab is top priority).
        if applyTimer == nil {
            applyTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self, !Switcher.shared.isNavigating else { return }
                ThumbnailStreamer.shared.applyPending { wid, img in
                    for p in self.panels { p.applyThumbnail(wid: wid, image: img) }
                }
            }
        }
    }

    func show(windows: [Win], selection: Int) {
        ensurePanels()
        for p in panels { _ = p.update(windows: windows, selection: selection) }
        // Instantly show any RAM-cached thumbnails (no re-capture wait on reopen).
        ThumbnailStreamer.shared.applyPending { wid, img in
            for p in panels { p.applyThumbnail(wid: wid, image: img) }
        }

        let n = windows.count
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.content == nil {
                do {
                    self.content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                } catch {
                    log("SCShareableContent failed: \(error.localizedDescription)")
                    return
                }
            }
            guard let content = self.content else { return }
            // Live streams for a sliding window around the selection: 5 behind, 15 ahead.
            let s = max(0, selection - 5)
            let e = min(n, selection + 15)
            ThumbnailStreamer.shared.sync(keep: Array(windows[s..<e]), content: content)
        }
    }

    func hide() {
        ThumbnailStreamer.shared.stopAll()
        for p in panels { p.hide() }
    }

}

// MARK: - Switcher state machine
final class Switcher {
    static let shared = Switcher()
    let mru = MRU()
    let overlay = Overlay()
    private var candidateIndex = 1
    private var active = false
    private var inventory: [Win] = []
    private var lastNavTime: TimeInterval = 0
    private var lastStepTime: TimeInterval = 0
    /// Auto-cycle rate while holding Option+Tab (throttles the raw key auto-repeat).
    static let minStepInterval: TimeInterval = 0.1   // ~10 windows/sec
    /// True while the user is actively navigating (Tab/scroll within the last 0.4s).
    /// Thumbnail UI updates yield to keep the Tab path at top priority.
    var isNavigating: Bool {
        active && Date().timeIntervalSince1970 - lastNavTime < 0.4
    }

    // Option+Tab (dir=+1) or Option+Shift+Tab (dir=-1) keydown
    func hotkeyFired(direction: Int) {
        log("hotkey dir=\(direction > 0 ? "fwd" : "back") active=\(active) mru=\(mru.list.count)")
        if inventory.isEmpty { rebuildInventory() }   // one-time fallback; bg refresh normally keeps it warm
        let n = mru.list.count
        guard n > 1 else { log("only \(n) windows — nothing to switch to"); overlay.hide(); return }
        if !active {
            active = true
            candidateIndex = 1
            lastNavTime = Date().timeIntervalSince1970
        } else {
            step(direction: direction)
            return
        }
        let ordered = mru.list.compactMap { e in inventory.first(where: { $0.wid == e.wid }) }
        log("selection \(candidateIndex + 1)/\(n)")
        overlay.show(windows: ordered, selection: candidateIndex)
    }

    /// Move the selection (keyboard Tab or mouse scroll).
    func step(direction: Int) {
        guard active else { return }
        let now = Date().timeIntervalSince1970
        // Throttle the key auto-repeat: holding Option+Tab fires ~30 keyDowns/sec,
        // but we only advance every minStepInterval for a comfortable cycle rate.
        if now - lastStepTime < Self.minStepInterval { return }
        lastStepTime = now
        lastNavTime = now
        let n = mru.list.count
        candidateIndex = (candidateIndex + direction + n) % n
        let ordered = mru.list.compactMap { e in inventory.first(where: { $0.wid == e.wid }) }
        log("selection \(candidateIndex + 1)/\(n)")
        overlay.show(windows: ordered, selection: candidateIndex)
    }

    /// Mouse click on a row → commit that window immediately.
    func selectAndCommit(_ idx: Int) {
        active = false
        candidateIndex = idx
        overlay.hide()
        let entry = mru.list[idx % mru.list.count]
        log("mouse commit → [\(entry.pid) wid=\(entry.wid)]")
        activateWindow(pid: entry.pid, wid: entry.wid)
    }

    // Option released → commit
    func flagsChanged(_ event: NSEvent) {
        let down = event.modifierFlags.contains(.option)
        log("flagsChanged: optionDown=\(down) active=\(active)")
        if !down && active { commit() }
    }

    // 300ms tick: keep MRU in sync with real focus + fallback commit
    private var lastFocused: (pid: pid_t, wid: CGWindowID)? = nil
    private var tickCount = 0
    private var debugCapturing = false   // suppress the Option-release fallback commit during a screenshot
    func tick() {
        // Screenshot trigger: create /tmp/opt-tab-shot to capture the overlay
        if FileManager.default.fileExists(atPath: "/tmp/opt-tab-shot") {
            try? FileManager.default.removeItem(atPath: "/tmp/opt-tab-shot")
            debugCaptureScreenshot()
            return
        }
        if active && !optionDownNow() && !debugCapturing {
            log("tick: Option released (fallback commit)")
            commit()
        }
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        guard let wid = focusedWindowID(pid: front.processIdentifier) else { return }
        if lastFocused?.wid != wid {
            log("focus → [\(front.localizedName ?? "?")] wid=\(wid)")
            lastFocused = (front.processIdentifier, wid)
            mru.moveToFront(front.processIdentifier, wid)   // reorder only on focus change
        }
        // Keep the inventory warm + current in the background — never on the Tab path.
        // FROZEN while the switcher is open: a mid-navigation refresh would prune the
        // MRU list to a smaller AX snapshot and make the total jump under the user.
        // The list is captured on press, stays stable while held, and refreshes on close.
        tickCount += 1
        if tickCount % 7 == 0 && !active {
            rebuildInventory()
        }
    }

    private func commit() {
        active = false
        overlay.hide()
        guard !mru.list.isEmpty else { return }
        let entry = mru.list[candidateIndex % mru.list.count]
        log("commit → [\(entry.pid) wid=\(entry.wid)]")
        activateWindow(pid: entry.pid, wid: entry.wid)
    }

    /// Show the overlay, let thumbnails render, then capture the whole screen to a PNG.
    func debugCaptureScreenshot() {
        log("screenshot: showing overlay + capturing…")
        if inventory.isEmpty { rebuildInventory() }
        active = true
        candidateIndex = 1
        let ordered = mru.list.compactMap { e in inventory.first(where: { $0.wid == e.wid }) }
        overlay.show(windows: ordered, selection: candidateIndex)
        debugCapturing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            Self.captureAndSaveScreen()
            self.overlay.hide()
            self.active = false
            self.debugCapturing = false
        }
    }

    static func captureAndSaveScreen() {
        let path = "/tmp/opt-tab-screenshot.png"
        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let display = content.displays.first else {
                    log("screenshot: no display found"); return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = Int(display.frame.width)
                config.height = Int(display.frame.height)
                config.showsCursor = true
                let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                let rep = NSBitmapImageRep(cgImage: img)
                guard let data = rep.representation(using: .png, properties: [:]) else {
                    log("screenshot: PNG encode failed"); return
                }
                try data.write(to: URL(fileURLWithPath: path))
                log("screenshot saved: \(path) (\(Int(img.width))x\(Int(img.height)))")
            } catch {
                log("screenshot failed: \(error.localizedDescription)")
            }
        }
    }

    func rebuildInventory() {
        inventory = allWindows()
        mru.prune(live: Set(inventory.map { $0.wid }),
                  newWindows: inventory.map { ($0.pid, $0.wid) })
        ThumbnailStreamer.shared.prune(live: Set(inventory.map { $0.wid }))
    }
}

// MARK: - Tab key tap (hold Option+Tab to auto-cycle, like Windows Alt+Tab)
// A CGEventTap on keyDown sees the system's key auto-repeat, so HOLDING Tab fires
// repeated events → auto-advance. Throttled in Switcher.step to a comfortable rate.
func installTabTap() {
    let mask = CGEventMask((1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue))
    guard let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,   // active: lets us CONSUME Option+Tab so the background app (Chrome) never sees it
        eventsOfInterest: mask,
        callback: { _, type, event, _ -> Unmanaged<CGEvent>? in
            if event.getIntegerValueField(.keyboardEventKeycode) == 48 {   // Tab
                let flags = event.flags
                if flags.contains(.maskAlternate) {                        // Option held
                    if type == .keyDown {
                        let direction = flags.contains(.maskShift) ? -1 : 1
                        DispatchQueue.main.async {
                            Switcher.shared.hotkeyFired(direction: direction)
                        }
                    }
                    return nil   // consume keyDown+keyUp: background apps don't react to Option+Tab
                }
            }
            return Unmanaged.passUnretained(event)
        },
        userInfo: nil
    ) else {
        log("Tab tap: failed to create (needs Accessibility permission)")
        return
    }
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    log("Tab tap installed: hold Option+Tab to auto-cycle down, Option+Shift+Tab up")
}

// MARK: - Main
if CommandLine.arguments.contains("--test") {
    let wins = allWindows()
    print("all windows (all spaces): \(wins.count)")
    for w in wins.prefix(20) {
        print("  pid=\(w.pid) wid=\(w.wid) [\(w.appName)] \(w.title.prefix(60))")
    }
    let front = NSWorkspace.shared.frontmostApplication
    if let f = front {
        print("frontmost: \(f.localizedName ?? "?") pid=\(f.processIdentifier) focusedWid=\(focusedWindowID(pid: f.processIdentifier).map(String.init) ?? "none")")
    }
    exit(0)
}
if CommandLine.arguments.contains("--show-overlay") {
    let wins = allWindows()
    let sw = Switcher.shared
    sw.overlay.show(windows: wins, selection: 1)
    print("overlay shown (selection 2/\(wins.count)); staying 6s")
    Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { _ in exit(0) }
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    NSApp.run()
    exit(0)
}
if CommandLine.arguments.contains("--activate") {
    let a = CommandLine.arguments
    guard let pid = Int32(a[a.firstIndex(of: "--activate")! + 1]),
          let wid = UInt32(a[a.firstIndex(of: "--activate")! + 2]) else { exit(1) }
    activateWindow(pid: pid, wid: wid)
    Thread.sleep(forTimeInterval: 1.5)
    let front = NSWorkspace.shared.frontmostApplication
    print("after activate: frontmost=\(front?.localizedName ?? "?") pid=\(front?.processIdentifier ?? -1) focusedWid=\(front.map { focusedWindowID(pid: $0.processIdentifier).map(String.init) ?? "none" } ?? "none")")
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no Dock icon

let trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
log("accessibility trusted: \(trusted)")
if screenCaptureAllowed() {
    log("screen recording: granted (live thumbnails enabled)")
} else {
    log("screen recording: NOT granted — thumbnails fall back to app icons. Grant in System Settings → Privacy & Security → Screen Recording, then restart opt-tab.")
}

installTabTap()
NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { e in
    Switcher.shared.flagsChanged(e)
}
Switcher.shared.rebuildInventory()   // warm the cache at launch (one-time, off the Tab path)
Switcher.shared.overlay.warmUp()      // pre-create panels so the first Tab is fast
Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
    Switcher.shared.tick()
}

log("opt-tab running: hold Option+Tab to auto-cycle down / Option+Shift+Tab up, release Option to commit (all Spaces, MRU order)")
app.run()
