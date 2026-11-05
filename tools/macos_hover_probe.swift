// Native AppKit reference for hover under a stationary pointer (docs/UI_FRAMEWORK_CORE.md,
// "Hover Under a Stationary Pointer"). Measures what the window server and AppKit report while the
// cursor does NOT move: windows and content are moved under it instead.
//
//   bash scripts/macos_hover_probe.sh [out.json]
//
// Never moves, warps or posts pointer events. It reads the cursor position once, places its window
// under it, and spawns a second process (`--foreign`, a different application) whose windows cover
// and uncover that point and which takes activation for the inactive-window phases. If the cursor
// moves during the run, the result is marked invalid.
//
// Output: one JSON document (stdout and the optional path) with every tracking-area event
// (area kind, phase, latency from the action that caused it) and the tracking-area options that
// standard AppKit controls install.
import AppKit
import QuartzCore
import WebKit

func now() -> Double { CACurrentMediaTime() }

// MARK: - Foreign process: another application's windows.

final class ForeignApp: NSObject, NSApplicationDelegate {
    var panel: NSPanel!
    var parking: NSWindow!
    func applicationDidFinishLaunching(_ note: Notification) {
        // A non-activating floating panel: another app's utility window above ours while we stay
        // active (inspectors, colour pickers, screenshot tools behave like this).
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 160, height: 120),
                        styleMask: [.titled, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: false)
        panel.level = .floating
        panel.title = "foreign"
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // A regular window kept away from the cursor: the target of activation.
        parking = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
                           styleMask: [.titled], backing: .buffered, defer: false)
        parking.title = "foreign-active"
        parking.isReleasedWhenClosed = false
        Thread.detachNewThread { [weak self] in
            while let line = readLine() {
                DispatchQueue.main.async { self?.handle(line) }
            }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        print("ready \(now())"); fflush(stdout)
    }
    func handle(_ line: String) {
        let parts = line.split(separator: " ").map(String.init)
        guard let cmd = parts.first else { return }
        let nums = parts.dropFirst().compactMap { Double($0) }
        var extra = ""
        switch cmd {
        case "cover":
            panel.setFrame(NSRect(x: nums[0], y: nums[1], width: nums[2], height: nums[3]), display: true)
            panel.orderFrontRegardless()
        case "uncover":
            panel.setFrameOrigin(NSPoint(x: nums[0], y: nums[1]))
        case "cover-clickthrough":
            // Same panel, but transparent to the mouse (overlays, HUDs).
            panel.ignoresMouseEvents = true
            panel.setFrame(NSRect(x: nums[0], y: nums[1], width: nums[2], height: nums[3]), display: true)
            panel.orderFrontRegardless()
        case "solid":
            panel.ignoresMouseEvents = false
        case "hide":
            panel.orderOut(nil)
        case "park":
            parking.setFrameOrigin(NSPoint(x: nums[0], y: nums[1]))
            parking.orderFrontRegardless()
        case "activate":
            NSApp.activate(ignoringOtherApps: true)
            parking.makeKeyAndOrderFront(nil)
        case "state":
            extra = " active=\(NSApp.isActive ? 1 : 0)"
        case "quit":
            print("done quit \(now())"); fflush(stdout)
            NSApp.terminate(nil)
            return
        default:
            break
        }
        print("done \(cmd) \(now())\(extra)"); fflush(stdout)
    }
}

// MARK: - Probe process: our window, tracking areas and standard controls.

struct Ev: Encodable {
    let t: Double
    let phase: String
    let target: String
    let kind: String
    let event: String
    let latency_ms: Double?
    /// `NSWindow.windowNumber(at:belowWindowWithWindowNumber:)` at the cursor names the window
    /// that received the event when it was delivered.
    let window_at_cursor_is_ours: Bool
}

var events: [Ev] = []
var phase = "setup"
var actionTime: Double = 0
var moves: [String: Int] = [:]

/// Tracking-area options under test. All use `.inVisibleRect` like the Zenit content view.
let areaKinds: [(String, NSTrackingArea.Options)] = [
    ("always", [.activeAlways]),
    ("activeApp", [.activeInActiveApp]),
    ("keyWindow", [.activeInKeyWindow]),
]

final class TrackView: NSView {
    let name: String
    init(name: String, frame: NSRect) { self.name = name; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        for (kind, opts) in areaKinds {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, opts],
                                           owner: self, userInfo: ["kind": kind]))
        }
    }
    func record(_ e: NSEvent, _ what: String) {
        let kind = (e.trackingArea?.userInfo?["kind"] as? String) ?? "?"
        let top = NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0)
        events.append(Ev(t: now(), phase: phase, target: name, kind: kind, event: what,
                         latency_ms: actionTime > 0 ? (now() - actionTime) * 1000 : nil,
                         window_at_cursor_is_ours: top == window?.windowNumber))
    }
    override func mouseEntered(with e: NSEvent) { record(e, "entered") }
    override func mouseExited(with e: NSEvent) { record(e, "exited") }
    override func mouseMoved(with e: NSEvent) {
        let kind = (e.trackingArea?.userInfo?["kind"] as? String) ?? "window"
        moves["\(phase)/\(name)/\(kind)", default: 0] += 1
    }
    override func draw(_ r: NSRect) { NSColor(white: 0.85, alpha: 1).setFill(); r.fill() }
}

final class Rows: NSView {
    override var isFlipped: Bool { true }
}

func optionNames(_ o: NSTrackingArea.Options) -> [String] {
    var n: [String] = []
    let table: [(NSTrackingArea.Options, String)] = [
        (.mouseEnteredAndExited, "mouseEnteredAndExited"), (.mouseMoved, "mouseMoved"), (.cursorUpdate, "cursorUpdate"),
        (.activeWhenFirstResponder, "activeWhenFirstResponder"), (.activeInKeyWindow, "activeInKeyWindow"),
        (.activeInActiveApp, "activeInActiveApp"), (.activeAlways, "activeAlways"), (.assumeInside, "assumeInside"),
        (.inVisibleRect, "inVisibleRect"), (.enabledDuringMouseDrag, "enabledDuringMouseDrag"),
    ]
    var rest = o.rawValue
    for (flag, name) in table where o.contains(flag) { n.append(name); rest &= ~flag.rawValue }
    if rest != 0 { n.append(String(format: "0x%lx", rest)) }
    return n
}

func dumpAreas(_ view: NSView, into out: inout [String: [[String]]], label: String) {
    var all: [[String]] = []
    func walk(_ v: NSView) {
        for a in v.trackingAreas { all.append(optionNames(a.options) + ["owner=\(type(of: a.owner as AnyObject))"]) }
        for s in v.subviews { walk(s) }
    }
    walk(view)
    out[label] = all
}

final class ProbeApp: NSObject, NSApplicationDelegate, NSToolbarDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var window: NSWindow!
    var other: NSWindow!
    var tracker: TrackView!
    var scroll: NSScrollView!
    var rows: [TrackView] = []
    var foreign: Process!
    var foreignIn: FileHandle!
    var pending: [String: (Double) -> Void] = [:]
    var cursor = NSPoint.zero
    var report: [String: Any] = [:]
    var controls: [String: [[String]]] = [:]
    var controlsInactive: [String: [[String]]] = [:]
    var controlViews: [(String, NSView)] = []
    var outPath: String?
    var states: [[String: Any]] = []
    var cursorInContent = NSPoint.zero

    func applicationDidFinishLaunching(_ note: Notification) {
        // Start only once the cursor has rested for 2 s (the user may be using the machine).
        var last = NSEvent.mouseLocation, since = now()
        let deadline = now() + 120
        while now() - since < 2 {
            if now() > deadline { FileHandle.standardError.write("cursor never rested\n".data(using: .utf8)!); exit(4) }
            usleep(100_000)
            let p = NSEvent.mouseLocation
            if p != last { last = p; since = now() }
        }
        cursor = last
        let rowH: CGFloat = 30
        // Window: cursor 150pt from the left and in the middle of a 30pt row of the scroll view.
        let content = NSRect(x: cursor.x - 150, y: cursor.y - 200, width: 520, height: 400)
        window = NSWindow(contentRect: content, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "hover probe"
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        let root = NSView(frame: NSRect(origin: .zero, size: content.size))
        window.contentView = root
        // Left column (x 0..300): a scroll view of rows under the cursor (placed once the window
        // has its final geometry) and a tracker view parked away from the cursor.
        scroll = NSScrollView(frame: NSRect(x: 0, y: 100, width: 300, height: 200))
        let doc = Rows(frame: NSRect(x: 0, y: 0, width: 300, height: rowH * 40))
        for i in 0..<40 {
            let r = TrackView(name: String(format: "row%02d", i), frame: NSRect(x: 0, y: CGFloat(i) * rowH, width: 300, height: rowH))
            doc.addSubview(r)
            rows.append(r)
        }
        scroll.documentView = doc
        scroll.hasVerticalScroller = true
        root.addSubview(scroll)
        tracker = TrackView(name: "tracker", frame: NSRect(x: 100, y: 10, width: 100, height: 30))
        root.addSubview(tracker)
        // Right column (x 320..): standard controls, only for their tracking-area options.
        var y: CGFloat = 360
        func place(_ name: String, _ v: NSView, _ h: CGFloat = 24) {
            v.frame = NSRect(x: 320, y: y, width: 180, height: h)
            root.addSubview(v); controlViews.append((name, v)); y -= h + 6
        }
        let recessed = NSButton(title: "recessed", target: nil, action: nil)
        recessed.bezelStyle = .accessoryBarAction
        recessed.showsBorderOnlyWhileMouseInside = true
        place("NSButton.showsBorderOnlyWhileMouseInside", recessed)
        place("NSButton.push", NSButton(title: "push", target: nil, action: nil))
        let popup = NSPopUpButton(frame: .zero, pullsDown: false); popup.addItems(withTitles: ["a", "b"])
        place("NSPopUpButton", popup)
        place("NSSegmentedControl", NSSegmentedControl(labels: ["a", "b"], trackingMode: .selectOne, target: nil, action: nil))
        place("NSSearchField", NSSearchField(frame: .zero))
        place("NSTextField.editable", NSTextField(string: "text"))
        place("NSSlider", NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil))
        let tableScroll = NSScrollView(); let table = NSTableView()
        table.addTableColumn(NSTableColumn(identifier: .init("c"))); table.dataSource = self; table.delegate = self
        tableScroll.documentView = table; tableScroll.hasVerticalScroller = true
        place("NSTableView(in NSScrollView)", tableScroll, 80)
        let tv = NSTextView(); place("NSTextView", tv, 30)
        place("NSColorWell", NSColorWell())
        place("NSPathControl", NSPathControl())
        let web = WKWebView(frame: .zero)
        web.loadHTMLString("<a href='#'>link</a>", baseURL: nil)
        place("WKWebView", web, 40)
        let toolbar = NSToolbar(identifier: "probe"); toolbar.delegate = self
        window.toolbar = toolbar
        // Our own second window, for the "covered by another window of the same app" case.
        other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 160, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        other.title = "same-app"
        other.isReleasedWhenClosed = false

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // Final geometry (title bar, toolbar): put the cursor 10pt into a row of the scroll view.
        let p = root.convert(window.convertPoint(fromScreen: cursor), from: nil)
        scroll.frame.origin.y = (p.y - 100).rounded()
        cursorInContent = p
        startForeign()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { 5 }
    func tableView(_ t: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? { NSTextField(labelWithString: "row \(row)") }
    func toolbarAllowedItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] { [.init("btn")] }
    func toolbarDefaultItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] { [.init("btn")] }
    func toolbar(_ t: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        item.image = NSImage(systemSymbolName: "star", accessibilityDescription: nil)
        item.label = "Star"; item.isBordered = true
        return item
    }

    func startForeign() {
        foreign = Process()
        foreign.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        foreign.arguments = ["--foreign"]
        let inPipe = Pipe(), outPipe = Pipe()
        foreign.standardInput = inPipe; foreign.standardOutput = outPipe
        foreignIn = inPipe.fileHandleForWriting
        try! foreign.run()
        Thread.detachNewThread { [weak self] in
            let h = outPipe.fileHandleForReading
            var buf = Data()
            while true {
                let chunk = h.availableData
                if chunk.isEmpty { break }
                buf.append(chunk)
                while let nl = buf.firstIndex(of: 10) {
                    let line = String(decoding: buf[..<nl], as: UTF8.self)
                    buf.removeSubrange(...nl)
                    DispatchQueue.main.async { self?.reply(line) }
                }
            }
        }
    }

    func reply(_ line: String) {
        let parts = line.split(separator: " ").map(String.init)
        if parts.first == "ready" { runPhases(); return }
        guard parts.count >= 3, parts[0] == "done" else { return }
        if parts.count > 3 { states.append(["phase": phase, "foreign": parts[3]]) }
        let t = Double(parts[2]) ?? now()
        if let k = pending.removeValue(forKey: parts[1]) { k(t) }
    }

    func send(_ cmd: String, _ then: @escaping (Double) -> Void) {
        pending[String(cmd.split(separator: " ")[0])] = then
        foreignIn.write((cmd + "\n").data(using: .utf8)!)
    }

    func snapshot(_ label: String) {
        let screen = NSEvent.mouseLocation
        let inWin = window.mouseLocationOutsideOfEventStream
        let top = NSWindow.windowNumber(at: screen, belowWindowWithWindowNumber: 0)
        states.append([
            "phase": phase, "label": label, "app_active": NSApp.isActive, "key": window.isKeyWindow,
            "cursor_moved": hypot(screen.x - cursor.x, screen.y - cursor.y) > 0.5,
            "mouseLocationOutsideOfEventStream": [inWin.x, inWin.y],
            "window_at_cursor_is_ours": top == window.windowNumber,
            "occlusion_visible": window.occlusionState.contains(.visible),
        ])
    }

    /// Run `step` as phase `name`, then collect events for `settle` seconds.
    func run(_ steps: [(String, (@escaping () -> Void) -> Void)], _ i: Int = 0) {
        guard i < steps.count else { finish(); return }
        let (name, step) = steps[i]
        phase = name
        actionTime = 0
        step {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.snapshot("after")
                if (self.states.last?["cursor_moved"] as? Bool) == true {
                    // The user moved the mouse: this run measures nothing. The script retries.
                    FileHandle.standardError.write("cursor moved during \(name)\n".data(using: .utf8)!)
                    self.send("quit") { _ in }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exit(3) }
                    return
                }
                self.run(steps, i + 1)
            }
        }
    }

    func local(_ action: @escaping () -> Void) -> (@escaping () -> Void) -> Void {
        { done in actionTime = now(); action(); done() }
    }
    func foreignStep(_ cmd: String) -> (@escaping () -> Void) -> Void {
        { done in self.send(cmd) { t in actionTime = t; done() } }
    }

    func runPhases() {
        let c = cursor
        let cover = String(format: "cover %.0f %.0f 160 120", c.x - 80, c.y - 60)
        let away = String(format: "uncover %.0f %.0f", c.x + 400, c.y - 60)
        let screen = window.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        let park = String(format: "park %.0f %.0f", screen.maxX - 140, screen.minY + 20)
        let frame = window.frame
        let rowH: CGFloat = 30
        // Put the cursor in the middle of a row: scroll so that row 03 sits under it.
        let underY = window.contentView!.convert(window.convertPoint(fromScreen: c), from: nil).y
        let steps: [(String, (@escaping () -> Void) -> Void)] = [
            ("settle", local { self.snapshot("before") }),
            ("dump-controls-active", local { for (n, v) in self.controlViews { dumpAreas(v, into: &self.controls, label: n) }
                if let tb = self.window.contentView?.superview { var t: [String: [[String]]] = [:]; dumpAreas(tb, into: &t, label: "frame"); self.report["window_frame_view_areas_active"] = t["frame"] } }),
            ("active/cover-foreign-panel", foreignStep(cover)),
            ("active/uncover-foreign-panel", foreignStep(away)),
            ("active/cover-clickthrough-panel", foreignStep(cover.replacingOccurrences(of: "cover", with: "cover-clickthrough"))),
            ("active/uncover-clickthrough-panel", foreignStep(away)),
            ("active/restore-solid-panel", foreignStep("solid")),
            ("active/cover-same-app-window", local { self.other.setFrame(NSRect(x: c.x - 80, y: c.y - 60, width: 160, height: 120), display: true); self.other.orderFront(nil) }),
            ("active/uncover-same-app-window", local { self.other.orderOut(nil) }),
            ("active/scroll-programmatic", local { self.scrollRows(by: 2 * rowH, underY: underY) }),
            ("active/move-tracker-under-cursor", local { self.tracker.frame.origin = NSPoint(x: self.cursorInContent.x - 50, y: self.cursorInContent.y - 15) }),
            ("active/move-tracker-away", local { self.tracker.frame.origin = NSPoint(x: 100, y: 10) }),
            ("active/move-window-away", local { self.window.setFrameOrigin(NSPoint(x: frame.minX + 600, y: frame.minY)) }),
            ("active/move-window-back", local { self.window.setFrameOrigin(frame.origin) }),
            ("park-foreign", foreignStep(park)),
            ("inactive/activate-foreign", foreignStep("activate")),
            ("inactive/foreign-state", foreignStep("state")),
            ("dump-controls-inactive", local { for (n, v) in self.controlViews { dumpAreas(v, into: &self.controlsInactive, label: n) } }),
            ("inactive/scroll-programmatic", local { self.scrollRows(by: 2 * rowH, underY: underY) }),
            ("inactive/move-tracker-under-cursor", local { self.tracker.frame.origin = NSPoint(x: self.cursorInContent.x - 50, y: self.cursorInContent.y - 15) }),
            ("inactive/move-tracker-away", local { self.tracker.frame.origin = NSPoint(x: 100, y: 10) }),
            ("inactive/cover-foreign-panel", foreignStep(cover)),
            ("inactive/uncover-foreign-panel", foreignStep(away)),
            ("inactive/move-window-away", local { self.window.setFrameOrigin(NSPoint(x: frame.minX + 600, y: frame.minY)) }),
            ("inactive/move-window-back", local { self.window.setFrameOrigin(frame.origin) }),
            ("reactivate", local { NSApp.activate(ignoringOtherApps: true); self.window.makeKeyAndOrderFront(nil) }),
            ("active-again/scroll-programmatic", local { self.scrollRows(by: 2 * rowH, underY: underY) }),
        ]
        run(steps)
    }

    func scrollRows(by dy: CGFloat, underY: CGFloat) {
        let clip = scroll.contentView
        clip.scroll(to: NSPoint(x: 0, y: clip.bounds.origin.y + dy))
        scroll.reflectScrolledClipView(clip)
    }

    func finish() {
        send("quit") { _ in }
        let screen = NSEvent.mouseLocation
        report["cursor"] = [cursor.x, cursor.y]
        report["cursor_moved_during_run"] = hypot(screen.x - cursor.x, screen.y - cursor.y) > 0.5 ||
            states.contains { ($0["cursor_moved"] as? Bool) == true }
        report["os"] = ProcessInfo.processInfo.operatingSystemVersionString
        report["states"] = states
        report["moves"] = moves
        report["standard_control_tracking_areas_active"] = controls
        report["standard_control_tracking_areas_inactive"] = controlsInactive
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        report["events"] = try! JSONSerialization.jsonObject(with: enc.encode(events))
        let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        if let p = outPath { try! data.write(to: URL(fileURLWithPath: p)) }
        FileHandle.standardOutput.write(data)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
if CommandLine.arguments.contains("--foreign") {
    let d = ForeignApp(); app.delegate = d; app.run()
} else {
    let d = ProbeApp()
    if let i = CommandLine.arguments.firstIndex(of: "--out"), i + 1 < CommandLine.arguments.count { d.outPath = CommandLine.arguments[i + 1] }
    app.delegate = d; app.run()
}
