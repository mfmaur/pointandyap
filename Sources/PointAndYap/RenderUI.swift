import AppKit
import SwiftUI

/// Draws the window and the pill offscreen, with example rows, for a design check.
@MainActor
enum RenderUI {
    static func run(to dir: URL) {
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let s = AppState()
        s.sessions = [
            SessionRow(dir: dir.appendingPathComponent("c"), date: Date(), duration: 21, points: 3, title: "Make this list sort by date, newest first", status: "open"),
            SessionRow(dir: dir, date: Date().addingTimeInterval(-900), duration: 38, points: 5, title: "This button should be blue, not grey, and here", status: "in_progress", by: "claude-code"),
            SessionRow(dir: dir.appendingPathComponent("b"), date: Date().addingTimeInterval(-3600), duration: 12, points: 2, title: "The date is wrong, it should say today", status: "done", by: "you"),
        ]
        s.mic = true; s.screen = true; s.ax = true
        s.updateReady = "0.1.3"
        write(MainView(state: s), "window.png", dir)
        s.updateReady = nil
        write(VStack(spacing: 0) { ForEach(s.sessions) { SessionRowView(row: $0, state: s); Divider() } }.frame(width: 352).padding(24).background(Color.white), "rows.png", dir)
        let n = AppState(); n.mic = true
        write(MainView(state: n), "window-access.png", dir)
        let st = AppState(); st.showSettings = true
        write(MainView(state: st), "settings.png", dir)
        let q = AppState(); q.askAgents = ["Claude Code", "Codex", "Cursor"]
        write(MainView(state: q), "agents.png", dir)
        let r = AppState(); r.phase = .recording(Date().addingTimeInterval(-14))
        write(PillView(state: r).padding(20).background(Color(hex: 0xDADCE0)), "pill.png", dir)
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
