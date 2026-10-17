import Foundation

/// The work queue: every session splits into items (one per numbered instruction, or per pointed sentence of the timeline
/// when no instructions exist). Each item is open, in progress (an agent works on it), or done; the state lives in the session's state.json
/// and every change goes through one lock, so several agents can work at once.
struct Item {
    var id: String            // "<session>#<n>"
    var session: String
    var n: Int
    var title: String
    var body: String
    var crops: [URL]
    var status: String        // open, in_progress, done
    var at: Date?
    var by: String?
    var note: String?
}

struct ItemState: Codable {
    var source: String        // instructions or timeline, frozen at first use so ids stay the same
    var items: [String: Entry] = [:]
    struct Entry: Codable { var status: String; var by: String?; var at: Date; var note: String? }
}

enum Items {
    static let lease: TimeInterval = 2 * 3600   // an item in progress that no one finished comes back after two hours

    // MARK: Splitting a session

    static func items(in dir: URL, state: ItemState?) -> (source: String, items: [Item]) {
        let id = dir.lastPathComponent
        let ins = try? String(contentsOf: dir.appendingPathComponent("instructions.md"), encoding: .utf8)
        let source = state?.source ?? (ins != nil ? "instructions" : "timeline")
        var out = source == "instructions" && ins != nil ? fromInstructions(ins!, dir: dir) : fromTimeline(dir)
        for i in out.indices {
            out[i].id = "\(id)#\(out[i].n)"
            out[i].session = id
            if let e = state?.items[String(out[i].n)] {
                // "taken" is the older name of in_progress.
                let working = e.status == "taken" || e.status == "in_progress"
                out[i].status = working ? (Date().timeIntervalSince(e.at) > lease ? "open" : "in_progress") : e.status
                out[i].by = e.by; out[i].note = e.note; out[i].at = e.at
            }
        }
        return (source, out)
    }

    /// "## 3. Title" sections; the summary and App lines above them go with every item as context.
    static func fromInstructions(_ text: String, dir: URL) -> [Item] {
        var head: [String] = [], cur: (n: Int, title: String, lines: [String])?, out: [Item] = []
        func flush() {
            guard let c = cur else { return }
            let body = (head + ["", "## \(c.n). \(c.title)"] + c.lines).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(Item(id: "", session: "", n: c.n, title: c.title, body: body, crops: cropPaths(in: c.lines.joined(separator: "\n"), dir: dir),
                            status: "open", at: nil))
        }
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("---") && cur != nil { break }
            if line.hasPrefix("## ") {
                flush(); cur = nil
                let rest = line.dropFirst(3)
                if let dot = rest.firstIndex(of: "."), let n = Int(rest[..<dot]) {
                    cur = (n, rest[rest.index(after: dot)...].trimmingCharacters(in: .whitespaces), [])
                } else if rest.lowercased().hasPrefix("open questions") {
                    cur = nil; head.append(""); head.append(line)   // asked of every item
                }
            } else if cur != nil {
                cur!.lines.append(line)
            } else {
                head.append(line)
            }
        }
        flush()
        return out
    }

    static func cropPaths(in text: String, dir: URL) -> [URL] {
        let re = try! NSRegularExpression(pattern: "crops/(\\d+)\\.jpg")
        let ns = text as NSString
        var seen = Set<String>()
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let name = ns.substring(with: m.range)
            guard seen.insert(name).inserted else { return nil }
            let u = dir.appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: u.path) ? u : nil
        }
    }

    /// One item per thing pointed at: a click, or a rest of half a second or more (shorter rests are cursor travel). Each
    /// word belongs to the point the cursor was on when it was said (0.3 s lead); words before the first point join it.
    /// Points in a row on the same element are one item; a point with no words is dropped.
    static func fromTimeline(_ dir: URL) -> [Item] {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("events.json")),
              let events = try? JSONDecoder.iso.decode(SessionEvents.self, from: data) else { return [] }
        let words = (try? Data(contentsOf: dir.appendingPathComponent("transcript.json")))
            .flatMap { try? JSONDecoder().decode([Word].self, from: $0) } ?? []
        guard !words.isEmpty else { return [] }

        func key(_ p: PointEvent) -> String {
            guard let e = p.element else { return "\(Int(p.at.x / 40)),\(Int(p.at.y / 40))" }
            return [e.role, e.title, e.label, e.value, e.identifier, e.frame.map { "\(Int($0.x)),\(Int($0.y))" }]
                .map { $0 ?? "" }.joined(separator: "|")
        }
        var anchors: [[PointEvent]] = []
        for p in events.points where p.kind == "click" || p.end - p.t >= 0.5 {
            if let last = anchors.last?.last, key(last) == key(p) { anchors[anchors.count - 1].append(p) } else { anchors.append([p]) }
        }
        var groups: [(points: [PointEvent], words: [Word])] = anchors.map { ($0, []) }
        if groups.isEmpty { groups = [([], [])] }   // spoken without pointing: one item
        for w in words {
            let i = groups.lastIndex { g in (g.points.first?.t ?? 0) - 0.3 <= w.start } ?? 0
            groups[i].words.append(w)
        }
        groups = groups.filter { !$0.words.isEmpty }

        return groups.enumerated().map { i, g in
            var said = g.words.map(\.text)
            for p in g.points {   // [n] after the word spoken closest to the point
                let wi = g.words.enumerated().min { abs($0.element.start - p.t) < abs($1.element.start - p.t) }?.offset ?? 0
                said[wi] += " [\(p.index + 1)]"
            }
            var lines = ["Said at \(Builder.clock(g.words[0].start)): \"\(said.joined(separator: " "))\""]
            var crops: [URL] = []
            for p in g.points {
                var l = "- [\(p.index + 1)] \(p.kind) in \(p.app ?? "?")"
                if let w = p.window { l += ", window \"\(w)\"" }
                if let u = p.url { l += ", \(u)" }
                l += ": \(Builder.describe(p))"
                if let path = p.element?.path, !path.isEmpty { l += "; inside \(path.suffix(5).joined(separator: " > "))" }
                let crop = dir.appendingPathComponent(String(format: "crops/%02d.jpg", p.index + 1))
                if FileManager.default.fileExists(atPath: crop.path) { l += "; crop `\(crop.path)`"; crops.append(crop) }
                lines.append(l)
            }
            let title = g.words.prefix(10).map(\.text).joined(separator: " ")
            return Item(id: "", session: "", n: i + 1, title: title, body: lines.joined(separator: "\n"), crops: crops, status: "open", at: nil)
        }
    }

    // MARK: State

    static func stateURL(_ dir: URL) -> URL { dir.appendingPathComponent("state.json") }

    static func readState(_ dir: URL) -> ItemState? {
        (try? Data(contentsOf: stateURL(dir))).flatMap { try? JSONDecoder.iso.decode(ItemState.self, from: $0) }
    }

    static func writeState(_ s: ItemState, _ dir: URL) {
        if let data = try? JSONEncoder.pretty.encode(s) { try? data.write(to: stateURL(dir), options: .atomic) }
    }

    /// Runs `body` under ~/Point/.lock (flock), so agents in separate processes never take the same item.
    static func locked<T>(_ body: () -> T) -> T {
        try? FileManager.default.createDirectory(at: Paths.root, withIntermediateDirectories: true)
        let fd = Darwin.open(Paths.root.deletingLastPathComponent().appendingPathComponent(".lock").path, O_CREAT | O_RDWR, 0o600)
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
        if fd >= 0 { flock(fd, LOCK_EX) }
        return body()
    }

    /// Every session that is processed (has session.md), oldest first.
    static func sessionDirs() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: Paths.root, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.hasDirectoryPath && FileManager.default.fileExists(atPath: $0.appendingPathComponent("session.md").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Open items oldest first; with `take`, they are marked in progress by `agent` before they are returned.
    static func openItems(limit: Int, take: Bool, agent: String) -> [Item] {
        locked {
            var out: [Item] = []
            for dir in sessionDirs() where out.count < limit {
                var st = readState(dir)
                let (source, items) = Self.items(in: dir, state: st)
                let free = items.filter { $0.status == "open" }.prefix(limit - out.count)
                guard !free.isEmpty else { continue }
                if take {
                    if st == nil { st = ItemState(source: source) }
                    for i in free { st!.items[String(i.n)] = .init(status: "in_progress", by: agent, at: Date(), note: nil) }
                    writeState(st!, dir)
                }
                out += free.map { var i = $0; if take { i.status = "in_progress"; i.by = agent; i.at = Date() }; return i }
            }
            return out
        }
    }

    /// Sets items to done or open. Returns what changed and what was not found.
    static func set(_ ids: [String], status: String, agent: String, note: String?) -> (changed: [String], missing: [String]) {
        locked {
            var changed: [String] = [], missing: [String] = []
            let bySession = Dictionary(grouping: ids) { String($0.split(separator: "#").first ?? "") }
            for (session, list) in bySession {
                let dir = Paths.root.appendingPathComponent(session)
                guard !session.isEmpty, !session.contains("/"), !session.contains(".."),
                      FileManager.default.fileExists(atPath: dir.appendingPathComponent("session.md").path) else { missing += list; continue }
                var st = readState(dir)
                let (source, items) = Self.items(in: dir, state: st)
                if st == nil { st = ItemState(source: source) }
                for id in list {
                    guard let item = items.first(where: { $0.id == id }) else { missing.append(id); continue }
                    if status == "in_progress", item.status == "done" || (item.status == "in_progress" && item.by != agent) {
                        missing.append("\(id) (\(item.status == "done" ? "done" : "in progress by \(item.by ?? "another agent")"))"); continue
                    }
                    st!.items[String(item.n)] = .init(status: status, by: agent, at: Date(), note: note)
                    changed.append(id)
                }
                writeState(st!, dir)
            }
            return (changed, missing)
        }
    }

    /// Counts for the window.
    static func counts(_ dir: URL) -> (open: Int, working: Int, done: Int) {
        let items = Self.items(in: dir, state: readState(dir)).items
        return (items.filter { $0.status == "open" }.count, items.filter { $0.status == "in_progress" }.count,
                items.filter { $0.status == "done" }.count)
    }

    /// Every item, oldest first, for an overview.
    static func all() -> [Item] { sessionDirs().flatMap { items(in: $0, state: readState($0)).items } }
}
