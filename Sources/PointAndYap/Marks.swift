import AppKit

/// While recording, over every screen: a dashed box on what is under the cursor and a numbered box on each thing pointed
/// at so far, as the live review bar draws them on a web page. Clicks go through it to the apps beneath, except while ⌥
/// is held or Area is on: then a drag draws an area, and a click on a number takes that one back. It is never in a
/// screenshot (Screen leaves this app's windows out).
@MainActor
final class MarksOverlay {
    private let recorder: Recorder
    private var panels: [(NSPanel, MarksView)] = []
    private var timer: Timer?
    private var hover: CGRect?
    private var probing = false
    private var lastProbe = CGPoint(x: -1, y: -1)
    private var dragFrom: CGPoint?
    private(set) var dragging = false
    /// Area is on from the pill: the next drag draws one, then it turns off.
    var areaOn = false { didSet { onChange?() } }
    var onChange: (() -> Void)?
    private(set) var count = 0

    init(recorder: Recorder) {
        self.recorder = recorder
        recorder.drawing = { [weak self] in self?.interactive ?? false }
        let h = NSScreen.screens.first?.frame.height ?? 0
        for screen in NSScreen.screens {
            let p = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)   // under the pill
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = false
            p.ignoresMouseEvents = true
            p.sharingType = .none
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let f = screen.frame
            let v = MarksView(frame: NSRect(origin: .zero, size: f.size), origin: CGPoint(x: f.minX, y: h - f.maxY))
            v.onDown = { [weak self] g in self?.down(g) }
            v.onDrag = { [weak self] g in self?.drag(g) }
            v.onUp = { [weak self] g in self?.up(g) }
            p.contentView = v
            p.orderFrontRegardless()
            panels.append((p, v))
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func close() {
        timer?.invalidate()
        for (p, _) in panels { p.orderOut(nil) }
        panels = []
        if cursorPushed { NSCursor.pop(); cursorPushed = false }
    }

    private var interactive: Bool { areaOn || dragging || NSEvent.modifierFlags.contains(.option) }
    private var cursorPushed = false

    private func tick() {
        let on = interactive
        for (p, _) in panels where p.ignoresMouseEvents == on { p.ignoresMouseEvents = !on }
        if on != cursorPushed { on ? NSCursor.crosshair.push() : NSCursor.pop(); cursorPushed = on }

        let c = Recorder.cursor()
        if !on, !probing, hypot(c.x - lastProbe.x, c.y - lastProbe.y) > 2 {
            probing = true; lastProbe = c
            let screen = NSScreen.screens.first?.frame.size ?? .zero
            DispatchQueue.global(qos: .userInteractive).async {
                var f = AXProbe.frame(at: c)
                if let r = f, r.width * r.height > 0.6 * screen.width * screen.height { f = nil }
                DispatchQueue.main.async { MainActor.assumeIsolated { self.hover = f; self.probing = false } }
            }
        }
        let marks = recorder.marks
        if marks.count != count { count = marks.count; onChange?() }
        let showHover = on || marks.contains(where: { !$0.area && $0.frame == hover }) ? nil : hover
        for (_, v) in panels { v.update(marks: marks, hover: showHover) }
    }

    private func down(_ g: CGPoint) {
        // A click on a number takes that one back.
        for (_, v) in panels { if let n = v.badge(at: g) { recorder.takeBack(n); return } }
        dragFrom = g; dragging = true
    }
    private func drag(_ g: CGPoint) {
        guard let a = dragFrom else { return }
        let r = CGRect(x: min(a.x, g.x), y: min(a.y, g.y), width: abs(g.x - a.x), height: abs(g.y - a.y))
        for (_, v) in panels { v.selection = r; v.needsDisplay = true }
    }
    private func up(_ g: CGPoint) {
        defer { dragFrom = nil; dragging = false; for (_, v) in panels { v.selection = nil; v.needsDisplay = true } }
        guard let a = dragFrom else { return }
        let r = CGRect(x: min(a.x, g.x), y: min(a.y, g.y), width: abs(g.x - a.x), height: abs(g.y - a.y))
        guard r.width >= 8, r.height >= 8 else { return }
        recorder.addArea(r)
        areaOn = false
    }
}

/// One screen's marks. Global top-left points in, drawn flipped.
final class MarksView: NSView {
    private let origin: CGPoint
    private var marks: [Recorder.Mark] = []
    private var hover: CGRect?
    var selection: CGRect?
    var onDown: ((CGPoint) -> Void)?
    var onDrag: ((CGPoint) -> Void)?
    var onUp: ((CGPoint) -> Void)?

    init(frame: NSRect, origin: CGPoint) { self.origin = origin; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func update(marks: [Recorder.Mark], hover: CGRect?) {
        guard marks.map(\.frame) != self.marks.map(\.frame) || marks.map(\.area) != self.marks.map(\.area) || hover != self.hover else { return }
        self.marks = marks; self.hover = hover
        needsDisplay = true
    }

    private func local(_ r: CGRect) -> CGRect { r.offsetBy(dx: -origin.x, dy: -origin.y) }
    private func global(_ e: NSEvent) -> CGPoint {
        let p = convert(e.locationInWindow, from: nil)
        return CGPoint(x: p.x + origin.x, y: p.y + origin.y)
    }
    private func badgeRect(_ r: CGRect) -> CGRect { CGRect(x: r.minX - 12, y: r.minY - 12, width: 22, height: 22) }

    /// The number of the badge at a global point, if one is there.
    func badge(at g: CGPoint) -> Int? {
        for (i, m) in marks.enumerated().reversed() where badgeRect(local(m.frame).insetBy(dx: -3, dy: -3)).insetBy(dx: -3, dy: -3).contains(CGPoint(x: g.x - origin.x, y: g.y - origin.y)) {
            return i + 1
        }
        return nil
    }

    override func mouseDown(with e: NSEvent) { onDown?(global(e)) }
    override func mouseDragged(with e: NSEvent) { onDrag?(global(e)) }
    override func mouseUp(with e: NSEvent) { onUp?(global(e)) }

    private static let red = NSColor(srgbRed: 0.898, green: 0.282, blue: 0.302, alpha: 1)

    override func draw(_ dirty: NSRect) {
        if let h = hover {
            let p = NSBezierPath(roundedRect: local(h).insetBy(dx: -3, dy: -3), xRadius: 6, yRadius: 6)
            p.lineWidth = 2
            p.setLineDash([5, 4], count: 2, phase: 0)
            Self.red.withAlphaComponent(0.6).setStroke()
            p.stroke()
        }
        for (i, m) in marks.enumerated() {
            let r = local(m.frame).insetBy(dx: -3, dy: -3)
            guard bounds.intersects(r) else { continue }
            let p = NSBezierPath(roundedRect: r, xRadius: m.area ? 2 : 6, yRadius: m.area ? 2 : 6)
            Self.red.withAlphaComponent(m.area ? 0.1 : 0.06).setFill(); p.fill()
            p.lineWidth = 2; Self.red.setStroke(); p.stroke()
            let b = badgeRect(r)
            let dot = NSBezierPath(ovalIn: b)
            Self.red.setFill(); dot.fill()
            dot.lineWidth = 2; NSColor.white.setStroke(); dot.stroke()
            let s = NSAttributedString(string: "\(i + 1)", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.white])
            let sz = s.size()
            s.draw(at: CGPoint(x: b.midX - sz.width / 2, y: b.midY - sz.height / 2))
        }
        if let sel = selection {
            let p = NSBezierPath(rect: local(sel))
            Self.red.withAlphaComponent(0.1).setFill(); p.fill()
            p.lineWidth = 2; Self.red.setStroke(); p.stroke()
        }
    }
}
