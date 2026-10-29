import AppKit

/// One recording: microphone, cursor at 30 Hz, points (cursor rests and clicks) with their Accessibility element, and
/// screenshots at the start, at every point and click, and every 3 seconds.
@MainActor
final class Recorder {
    let dir: URL
    private let audio = AudioRecorder()
    private let t0 = Date()
    private var timer: Timer?
    private var samples: [Sample] = []
    private var points: [PointEvent] = []
    private var frames: [Frame] = []
    private var pendingFrames = 0
    private var frameCounter = 0
    private var lastFrameT = -10.0
    private var lastFrameName: String?

    // Cursor rest detection.
    private var anchor = CGPoint.zero
    private var anchorT = 0.0
    private var restEmitted = false
    private var wasDown = false
    private static let restRadius = 8.0
    private static let restTime = 0.35

    /// The app's own UI (the pill), in global top-left points: nothing there is a point.
    var ignore: (() -> CGRect?)?
    /// True while a drag draws an area: the mouse is ours then, not a click or a rest.
    var drawing: (() -> Bool)?

    private var dropped: Set<Int> = []   // taken back: left out when it stops
    private var areas: Set<Int> = []

    init() { dir = Paths.newSession() }

    private var now: Double { Date().timeIntervalSince(t0) }

    /// The cursor in global top-left coordinates.
    static func cursor() -> CGPoint {
        let p = NSEvent.mouseLocation
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: p.x, y: h - p.y)
    }

    func start() throws {
        try audio.start(to: dir.appendingPathComponent("audio.caf"))
        anchor = Self.cursor()
        takeFrame(reason: "start", at: anchor)
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        let t = now
        let p = Self.cursor()
        let down = NSEvent.pressedMouseButtons != 0
        samples.append(Sample(t: round3(t), x: round1(p.x), y: round1(p.y), down: down))

        if drawing?() == true { wasDown = down; anchor = p; anchorT = t; restEmitted = true; return }
        if down && !wasDown { addPoint(kind: "click", at: p, t: t) }
        wasDown = down

        if hypot(p.x - anchor.x, p.y - anchor.y) > Self.restRadius {
            if restEmitted, let i = points.lastIndex(where: { $0.kind == "dwell" }), points[i].end == points[i].t {
                points[i].end = round3(t)
            }
            anchor = p; anchorT = t; restEmitted = false
        } else if !restEmitted && t - anchorT >= Self.restTime {
            restEmitted = true
            addPoint(kind: "dwell", at: anchor, t: anchorT)
        }

        if t - lastFrameT >= 3 { takeFrame(reason: "interval", at: p) }
    }

    private func addPoint(kind: String, at p: CGPoint, t: Double) {
        if let r = ignore?(), r.contains(p) { return }
        let index = points.count
        let app = NSWorkspace.shared.frontmostApplication
        let frame = takeFrame(reason: kind, at: p)
        points.append(PointEvent(index: index, t: round3(t), end: round3(t), at: Pt(x: round1(p.x), y: round1(p.y)),
                                 kind: kind, app: app?.localizedName, bundleID: app?.bundleIdentifier,
                                 window: nil, url: nil, element: nil, frame: frame))
        DispatchQueue.global(qos: .userInitiated).async {
            let (el, window, url) = AXProbe.element(at: p)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard index < self.points.count else { return }
                    self.points[index].element = el
                    self.points[index].window = window
                    self.points[index].url = url
                }
            }
        }
    }

    // MARK: Marks

    /// What has been pointed at so far, numbered as the request will name it: a click or a rest of half a second, one per
    /// element (or area).
    struct Mark { var key: String; var frame: CGRect; var area: Bool }
    var marks: [Mark] {
        var out: [Mark] = []
        let t = now
        for p in points where !dropped.contains(p.index) {
            let end = p.end == p.t && p.kind == "dwell" ? t : p.end
            guard p.kind == "click" || end - p.t >= 0.5, let k = key(p), let f = p.element?.frame?.cg, !out.contains(where: { $0.key == k }) else { continue }
            out.append(Mark(key: k, frame: f, area: areas.contains(p.index)))
        }
        return out
    }

    private func key(_ p: PointEvent) -> String? {
        if areas.contains(p.index) { return "area \(p.index)" }
        guard let e = p.element, let f = e.frame else { return nil }
        return "\(e.role ?? "") \(Int(f.x)) \(Int(f.y)) \(Int(f.w)) \(Int(f.h))"
    }

    /// Takes back the n-th mark: every point on that element (or that area) is left out.
    func takeBack(_ n: Int) {
        let all = marks
        guard n >= 1, n <= all.count else { return }
        let k = all[n - 1].key
        for p in points where key(p) == k { dropped.insert(p.index) }
        restEmitted = true   // resting there a moment longer does not put it straight back
    }

    /// A dragged area (global top-left): pointed at like a click, framed as the area.
    func addArea(_ r: CGRect) {
        let index = points.count, t = now
        let app = NSWorkspace.shared.frontmostApplication
        let c = CGPoint(x: r.midX, y: r.midY)
        let frame = takeFrame(reason: "click", at: c)
        areas.insert(index)
        points.append(PointEvent(index: index, t: round3(t), end: round3(t), at: Pt(x: round1(c.x), y: round1(c.y)),
                                 kind: "click", app: app?.localizedName, bundleID: app?.bundleIdentifier, window: nil, url: nil,
                                 element: Element(role: "area", frame: Rect(r), path: []), frame: frame))
        DispatchQueue.global(qos: .userInitiated).async {
            let (el, window, url) = AXProbe.element(around: r)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard index < self.points.count else { return }
                    if let el { self.points[index].element = el }
                    self.points[index].window = window
                    self.points[index].url = url
                }
            }
        }
    }

    @discardableResult
    private func takeFrame(reason: String, at p: CGPoint) -> String {
        // Two points close together share one frame.
        if now - lastFrameT < 0.4, let last = lastFrameName { return last }
        frameCounter += 1
        let name = String(format: "frames/%03d.jpg", frameCounter)
        let t = now
        lastFrameT = t
        lastFrameName = name
        pendingFrames += 1
        let url = dir.appendingPathComponent(name)
        Task { @MainActor in
            if let r = await Screen.capture(at: p, to: url) {
                frames.append(Frame(file: name, t: round3(t), display: Rect(r.display), scale: r.scale, reason: reason))
            }
            pendingFrames -= 1
        }
        return name
    }

    /// Stops and moves the recording to the Trash.
    func cancel() {
        timer?.invalidate()
        audio.stop()
        // To the Trash, not deleted: a stray Esc can be undone from there. Wait for screenshots still being written.
        let dir = self.dir
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { try? FileManager.default.trashItem(at: dir, resultingItemURL: nil) }
    }

    /// Stops, waits for pending screenshots and Accessibility reads, writes events.json.
    func stop() async -> URL {
        timer?.invalidate()
        audio.stop()
        let duration = now
        for _ in 0..<40 where pendingFrames > 0 { try? await Task.sleep(nanoseconds: 50_000_000) }
        try? await Task.sleep(nanoseconds: 300_000_000)
        if let i = points.lastIndex(where: { $0.kind == "dwell" }), points[i].end == points[i].t { points[i].end = round3(duration) }
        if !dropped.isEmpty {
            points = points.filter { !dropped.contains($0.index) }
            for i in points.indices { points[i].index = i }
        }
        let known = Set(frames.map(\.file))
        for i in points.indices where points[i].frame.map({ !known.contains($0) }) ?? false { points[i].frame = nil }
        let events = SessionEvents(started: t0, duration: round3(duration), samples: samples, points: points,
                                   frames: frames.sorted { $0.t < $1.t })
        if let data = try? JSONEncoder.pretty.encode(events) {
            try? data.write(to: dir.appendingPathComponent("events.json"))
        }
        return dir
    }
}

func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
