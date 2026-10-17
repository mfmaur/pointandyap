import AppKit
import Foundation

/// Turns a recorded session (events.json, frames, words) into crops and session.md, without a model.
enum Builder {
    struct Sentence { var words: [Word]; var start: Double; var end: Double; var points: [Int] }

    static func sentences(_ words: [Word]) -> [Sentence] {
        var out: [Sentence] = []
        var cur: [Word] = []
        for w in words {
            if let last = cur.last, w.start - last.end > 0.7 {
                out.append(Sentence(words: cur, start: cur[0].start, end: last.end, points: [])); cur = []
            }
            cur.append(w)
            if let c = w.text.last, ".?!".contains(c) {
                out.append(Sentence(words: cur, start: cur[0].start, end: w.end, points: [])); cur = []
            }
        }
        if let last = cur.last { out.append(Sentence(words: cur, start: cur[0].start, end: last.end, points: [])) }
        return out
    }

    /// Each point joins the sentence it overlaps most (0.5 s slack), else the nearest within 1.5 s; clicks always join one.
    static func attach(_ points: [PointEvent], to sentences: inout [Sentence]) -> [Int] {
        var loose: [Int] = []
        for p in points {
            var best: (i: Int, score: Double)?
            for (i, s) in sentences.enumerated() {
                let overlap = min(p.end, s.end + 0.5) - max(p.t, s.start - 0.5)
                let gap = max(s.start - p.end, p.t - s.end, 0)
                let score = overlap > 0 ? overlap : -gap
                if best == nil || score > best!.score { best = (i, score) }
            }
            if let b = best, b.score > -1.5 || p.kind == "click" { sentences[b.i].points.append(p.index) } else { loose.append(p.index) }
        }
        return loose
    }

    /// The sentence text with [n] markers after the word spoken closest to each point's start.
    static func marked(_ s: Sentence, _ points: [PointEvent]) -> String {
        var after: [Int: [Int]] = [:]
        for idx in s.points {
            let p = points[idx]
            let wi = s.words.enumerated().min { abs($0.element.start - p.t) < abs($1.element.start - p.t) }?.offset ?? 0
            after[wi, default: []].append(idx + 1)
        }
        return s.words.enumerated().map { i, w in
            w.text + (after[i].map { " " + $0.map { "[\($0)]" }.joined() } ?? "")
        }.joined(separator: " ")
    }

    // MARK: Crops

    static func crop(_ p: PointEvent, frames: [Frame], dir: URL) -> String? {
        guard let name = p.frame, let f = frames.first(where: { $0.file == name }),
              let img = NSImage(contentsOf: dir.appendingPathComponent(name))?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        let d = f.display.cg, s = f.scale
        let cw = min(900.0, d.width), ch = min(600.0, d.height)
        var r = CGRect(x: p.at.x - cw / 2, y: p.at.y - ch / 2, width: cw, height: ch)
        r.origin.x = max(d.minX, min(r.origin.x, d.maxX - cw))
        r.origin.y = max(d.minY, min(r.origin.y, d.maxY - ch))
        let px = CGRect(x: (r.minX - d.minX) * s, y: (r.minY - d.minY) * s, width: cw * s, height: ch * s)
        guard let cut = img.cropping(to: px) else { return nil }

        let outW = min(1200.0, cut.width.d), k = outW / cut.width.d, outH = cut.height.d * k
        guard let ctx = CGContext(data: nil, width: Int(outW), height: Int(outH), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(cut, in: CGRect(x: 0, y: 0, width: outW, height: outH))
        // Points to image space (CGContext has a bottom-left origin).
        let toImg = { (x: Double, y: Double) in CGPoint(x: (x - r.minX) * s * k, y: outH - (y - r.minY) * s * k) }
        if let ef = p.element?.frame?.cg, ef.width < cw * 0.9 || ef.height < ch * 0.9 {
            let a = toImg(ef.minX, ef.maxY), b = toImg(ef.maxX, ef.minY)
            ctx.setStrokeColor(NSColor.systemYellow.withAlphaComponent(0.9).cgColor)
            ctx.setLineWidth(2 * s * k)
            ctx.stroke(CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y))
        }
        let c = toImg(p.at.x, p.at.y), rad = 16 * s * k
        ctx.setStrokeColor(NSColor.systemRed.cgColor)
        ctx.setLineWidth(3 * s * k)
        ctx.strokeEllipse(in: CGRect(x: c.x - rad, y: c.y - rad, width: rad * 2, height: rad * 2))
        ctx.setFillColor(NSColor.systemRed.cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - 2 * s * k, y: c.y - 2 * s * k, width: 4 * s * k, height: 4 * s * k))
        guard let out = ctx.makeImage() else { return nil }
        let file = String(format: "crops/%02d.jpg", p.index + 1)
        return Screen.write(out, to: dir.appendingPathComponent(file), quality: 0.8) ? file : nil
    }

    // MARK: session.md

    static func describe(_ p: PointEvent) -> String {
        var parts: [String] = []
        if let e = p.element {
            var what = e.role ?? "element"
            if let sub = e.subrole { what += "/\(sub)" }
            let name = e.title ?? e.label ?? e.value
            if let name { what += " \"\(name)\"" }
            parts.append(what)
            if let v = e.value, v != name { parts.append("value \"\(v)\"") }
            if let h = e.help { parts.append("help \"\(h)\"") }
            if let id = e.identifier { parts.append("identifier `\(id)`") }
        } else {
            parts.append("no Accessibility element")
        }
        return parts.joined(separator: ", ")
    }

    struct Output { var markdown: String; var crops: [Int: String]; var attached: [Int] }

    static func build(dir: URL, events: SessionEvents, words: [Word]) -> Output {
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("crops"), withIntermediateDirectories: true)
        var sents = sentences(words)
        let loose = attach(events.points, to: &sents)
        var crops: [Int: String] = [:]
        let attached = sents.flatMap(\.points)
        for i in attached { if let c = crop(events.points[i], frames: events.frames, dir: dir) { crops[i] = c } }

        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm"
        let apps = Array(Set(events.points.compactMap { p in p.app.map { "\($0) (\(p.bundleID ?? "?"))" } })).sorted()
        var md = "# Point session \(df.string(from: events.started)) (\(Int(events.duration)) s)\n\n"
        md += "Folder: `\(dir.path)`\n"
        if !apps.isEmpty { md += "Apps pointed at: \(apps.joined(separator: ", "))\n" }
        md += "\nMarkers like [3] show where the cursor rested or clicked while that word was spoken. Coordinates are screen "
        md += "points from the top left of the main display. Crops: red ring is the cursor, yellow box is the element's frame.\n"

        md += "\n## Timeline\n"
        for s in sents {
            md += "\n**[\(clock(s.start))] \"\(marked(s, events.points))\"**\n"
            for i in s.points {
                let p = events.points[i]
                var line = "- [\(i + 1)] \(p.kind) at (\(Int(p.at.x)), \(Int(p.at.y))), \(clock(p.t))"
                if let a = p.app { line += " in \(a)" }
                if let w = p.window { line += ", window \"\(w)\"" }
                if let u = p.url { line += ", \(u)" }
                line += ": \(describe(p))"
                md += line + "\n"
                if let path = p.element?.path, !path.isEmpty { md += "  - inside: \(path.suffix(6).joined(separator: " > "))\n" }
                if let c = crops[i] { md += "  - crop: `\(dir.appendingPathComponent(c).path)`\n" }
            }
        }
        if words.isEmpty { md += "\n(No speech recognised.)\n" }
        if !loose.isEmpty {
            md += "\n## Points made while silent (probably cursor travel)\n\n"
            for i in loose {
                let p = events.points[i]
                md += "- [\(i + 1)] \(clock(p.t)) in \(p.app ?? "?"): \(describe(p))\n"
            }
        }
        md += "\n## Transcript\n\n" + words.map(\.text).joined(separator: " ") + "\n"
        try? md.write(to: dir.appendingPathComponent("session.md"), atomically: true, encoding: .utf8)
        return Output(markdown: md, crops: crops, attached: attached)
    }

    static func clock(_ t: Double) -> String { String(format: "%02d:%02d", Int(t) / 60, Int(t) % 60) }
}

private extension Int { var d: Double { Double(self) } }
