import Foundation

/// The work queue: each recording is one item (an agent does everything said in it, then marks it done). Each item is open, in progress (an agent works on it), or done; the state lives in the session's state.json
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
    var source: String        // "session"; older builds wrote "timeline"
    var items: [String: Entry] = [:]
    struct Entry: Codable { var status: String; var by: String?; var at: Date; var note: String? }
}

enum Items {
    static let lease: TimeInterval = 2 * 3600   // an item in progress that no one finished comes back after two hours

    // MARK: Splitting a session

    static func items(in dir: URL, state: ItemState?) -> (source: String, items: [Item]) {
        let id = dir.lastPathComponent
        let source = "session"
        var out = sessionItem(dir).map { [$0] } ?? []
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

    /// The whole recording as one item: everything said, with [n] where the cursor was, and every click or rest of half
    /// a second or more (shorter rests are cursor travel; repeats on the same element count once).
    static func sessionItem(_ dir: URL) -> Item? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("events.json")),
              let events = try? JSONDecoder.iso.decode(SessionEvents.self, from: data) else { return nil }
        let words = (try? Data(contentsOf: dir.appendingPathComponent("transcript.json")))
            .flatMap { try? JSONDecoder().decode([Word].self, from: $0) } ?? []
        guard !words.isEmpty else { return nil }
        var sents = Builder.sentences(words)
        _ = Builder.attach(events.points, to: &sents)
        var lines = ["Said (\(Builder.clock(words[0].start)) to \(Builder.clock(words[words.count - 1].end))): \""
                     + sents.map { Builder.marked($0, events.points) }.joined(separator: " ") + "\"", "", "Pointed at:"]
        var crops: [URL] = [], last: String?
        for idx in sents.flatMap(\.points) {
            let p = events.points[idx]
            guard p.kind == "click" || p.end - p.t >= 0.5 else { continue }
            let key = [p.element?.role, p.element?.title, p.element?.value, p.element?.identifier].map { $0 ?? "" }.joined(separator: "|")
            if key == last, p.kind != "click" { continue }
            last = key
            lines.append(pointLine(p, dir, &crops))
        }
        if lines.count == 3 { lines.removeLast(2) }
        let title = words.prefix(12).map(\.text).joined(separator: " ")
        return Item(id: "", session: "", n: 1, title: title, body: lines.joined(separator: "\n"), crops: crops, status: "open", at: nil)
    }

    static func pointLine(_ p: PointEvent, _ dir: URL, _ crops: inout [URL]) -> String {
        var l = "- [\(p.index + 1)] \(p.kind) in \(p.app ?? "?")"
        if let w = p.window { l += ", window \"\(w)\"" }
        if let u = p.url { l += ", \(u)" }
        l += ": \(Builder.describe(p))"
        if let path = p.element?.path, !path.isEmpty { l += "; inside \(path.suffix(5).joined(separator: " > "))" }
        let crop = dir.appendingPathComponent(String(format: "crops/%02d.jpg", p.index + 1))
        if FileManager.default.fileExists(atPath: crop.path) { l += "; crop `\(crop.path)`"; crops.append(crop) }
        return l
    }

    // MARK: State

    static func stateURL(_ dir: URL) -> URL { dir.appendingPathComponent("state.json") }

    static func readState(_ dir: URL) -> ItemState? {
        (try? Data(contentsOf: stateURL(dir))).flatMap { try? JSONDecoder.iso.decode(ItemState.self, from: $0) }
    }

    static func writeState(_ s: ItemState, _ dir: URL) {
        if let data = try? JSONEncoder.pretty.encode(s) { try? data.write(to: stateURL(dir), options: .atomic) }
    }

    /// Runs `body` under ~/PointAndYap/.lock (flock), so agents in separate processes never take the same item.
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

    /// Every item, oldest first, for an overview.
    static func all() -> [Item] { sessionDirs().flatMap { items(in: $0, state: readState($0)).items } }
}
