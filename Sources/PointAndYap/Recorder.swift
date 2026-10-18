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
