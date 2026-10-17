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
            SessionRow(dir: dir, date: Date(), duration: 38, points: 5, title: "This button should be blue, not grey, and here", hasInstructions: true, open: 2, done: 1),
            SessionRow(dir: dir.appendingPathComponent("b"), date: Date().addingTimeInterval(-3600), duration: 12, points: 2, title: "The date is wrong, it should say today", hasInstructions: false, open: 0, done: 3),
        ]
        s.mic = true; s.screen = true; s.ax = true
        write(MainView(state: s), "window.png", dir)
        write(VStack(spacing: 0) { ForEach(s.sessions) { SessionRowView(row: $0, state: s); Divider() } }.frame(width: 352).padding(24).background(Color.white), "rows.png", dir)
        let n = AppState(); n.mic = true
        write(MainView(state: n), "window-access.png", dir)
        let r = AppState(); r.phase = .recording(Date().addingTimeInterval(-14))
        write(PillView(state: r).padding(20).background(Color(hex: 0xDADCE0)), "pill.png", dir)
    }

    private static func write<V: View>(_ v: V, _ name: String, _ dir: URL) {
        let r = ImageRenderer(content: v.environment(\.colorScheme, .light))
        r.scale = 2
        guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { print("render failed \(name)"); return }
        try? png.write(to: dir.appendingPathComponent(name))
        print("wrote \(name)")
    }
}
