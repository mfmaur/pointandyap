import AppKit
import SwiftUI

/// Draws the window and the pill offscreen, with example rows, for a design check.
@MainActor
enum RenderUI {
    nonisolated(unsafe) static var active = false
    static func run(to dir: URL) {
        active = true
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let s = AppState()
        s.sessions = [
            SessionRow(dir: dir.appendingPathComponent("d"), date: Date(), duration: 9, points: 2, title: "This button should say Store instead of Save", status: "triage", author: "Dana"),
            SessionRow(dir: dir.appendingPathComponent("c"), date: Date().addingTimeInterval(-300), duration: 21, points: 3, title: "Make this list sort by date, newest first", status: "open"),
            SessionRow(dir: dir.appendingPathComponent("s"), date: Date().addingTimeInterval(-600), duration: 2, points: 0, title: "No speech", noSpeech: true),
            SessionRow(dir: dir, date: Date().addingTimeInterval(-900), duration: 38, points: 5, title: "This button should be blue, not grey, and here", status: "in_progress", by: "claude-code"),
            SessionRow(dir: dir.appendingPathComponent("b"), date: Date().addingTimeInterval(-3600), duration: 12, points: 2, title: "The date is wrong, it should say today", status: "done", by: "you"),
        ]
        s.mic = true; s.screen = true; s.ax = true
        s.updateReady = "0.1.3"
        s.showWelcome = false
        write(MainView(state: s), "window.png", dir)
        s.invite = JoinRecord(id: "x", relay: "", key: "", ownerKey: "", from: "Zeshan")
        write(MainView(state: s), "window-invite.png", dir)
        s.invite = nil
        s.joined = JoinRecord(id: "x", relay: "", key: "", ownerKey: "", from: "Zeshan")
        s.sessions = [
            SessionRow(dir: dir.appendingPathComponent("e"), date: Date(), duration: 14, points: 2, title: "This filter should remember what I picked", status: "triage", by: "sending to Zeshan"),
            SessionRow(dir: dir.appendingPathComponent("f"), date: Date().addingTimeInterval(-400), duration: 8, points: 1, title: "The empty state here is confusing", status: "done", by: "you", note: "Sent to Zeshan"),
        ]
        write(MainView(state: s), "window-joined.png", dir)
        s.joined = nil
        let ready = s.updateReady
        s.updateReady = nil
        s.pickingPort = true
        s.devServers = [.init(port: 5173, name: "node"), .init(port: 3000, name: "node")]
        write(MainView(state: s), "window-golive.png", dir)
        s.pickingPort = false
        s.live = LiveSession(upstream: 5173, owner: "Zeshan")
        s.livePeople = ["Dana", "Sam"]
        s.liveAgents = ["Claude Code"]
        s.sessions = [SessionRow(dir: dir.appendingPathComponent("g"), date: Date(), duration: 7, points: 3, title: "This counter button should be green. And the heading", status: "triage", by: "Dana", author: "Dana", requests: 2),
                      SessionRow(dir: dir.appendingPathComponent("h"), date: Date().addingTimeInterval(-240), duration: 5, points: 1, title: "The card should have more space around it", status: "done", by: "claude-code", author: "Sam", confirmed: true)]
        write(MainView(state: s), "window-live.png", dir)
        write(LiveCard(state: s, settingsOpen: true).frame(width: 352).padding(24).background(Color.white), "live-settings.png", dir)
        s.livePeople = []; s.liveAgents = []
        write(LiveCard(state: s).frame(width: 352).padding(24).background(Color.white), "live-empty.png", dir)
        s.livePeople = ["Dana", "Sam"]; s.liveAgents = ["Claude Code"]
        s.live = nil; s.liveStarting = true
        write(LiveCard(state: s).frame(width: 352).padding(24).background(Color.white), "live-starting.png", dir)
        s.liveStarting = false
        s.live = nil
        s.liveAgents = []
        s.updateReady = ready
        s.updateReady = nil
        s.showWelcome = true
        write(MainView(state: s), "welcome.png", dir)
        s.showWelcome = false
        write(VStack(spacing: 0) { ForEach(s.sessions) { SessionRowView(row: $0, state: s); Divider() } }.frame(width: 352).padding(24).background(Color.white), "rows.png", dir)
        // A real recording, opened: POINTANDYAP_RENDER_SESSION=<session folder>.
        if let p = ProcessInfo.processInfo.environment["POINTANDYAP_RENDER_SESSION"] {
            let d = URL(fileURLWithPath: p)
            let row = SessionRow(dir: d, date: Date(), duration: 7, points: 3, title: "This counter button should be green. And the", status: "done", by: "claude-code", requests: 2)
            write(SessionRowView(row: row, state: s, open: true).frame(width: 352).padding(24).background(Color.white), "row-open.png", dir)
        }
        let n = AppState(); n.mic = true
        write(MainView(state: n), "window-access.png", dir)
        let st = AppState(); st.showSettings = true
        write(MainView(state: st), "settings.png", dir)
        let q = AppState(); q.askAgents = ["Claude Code", "Codex", "Cursor"]
        write(MainView(state: q), "agents.png", dir)
        let r = AppState(); r.phase = .recording(Date().addingTimeInterval(-14))
        write(PillView(state: r).padding(20).background(Color(hex: 0xDADCE0)), "pill.png", dir)
        r.pointed = 3
        write(PillView(state: r).padding(20).background(Color(hex: 0xDADCE0)), "pill-pointed.png", dir)
        r.areaOn = true
        write(PillView(state: r).padding(20).background(Color(hex: 0xDADCE0)), "pill-area.png", dir)
    }

    /// Through a hosting view in an offscreen window, so AppKit controls (switches, pickers, scroll views) draw too.
    private static func write<V: View>(_ v: V, _ name: String, _ dir: URL) {
        let host = NSHostingView(rootView: v.environment(\.colorScheme, .light))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: .aqua)
        win.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { print("render failed \(name)"); return }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { print("render failed \(name)"); return }
        try? png.write(to: dir.appendingPathComponent(name))
        print("wrote \(name)")
    }
}
