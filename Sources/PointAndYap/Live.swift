import AppKit
import Foundation

/// Live review: `PointAndYap --live 5173` shares the app running on this Mac's localhost:5173 through a link. Whoever
/// opens it uses the real, running app in their own browser, with a review bar on top: they point and talk as the user
/// does on their Mac, and each recording becomes an item here, with the element's source file when the page's framework
/// says it, the page's errors, and the guest's screen as they saw it. Everyone in the link sees each other's cursors and
/// the queue as it moves; when an agent marks someone's item done, the dev server's hot reload already shows them the fix,
/// and they say "looks right" or "not yet" on the spot.
///
/// The link is a free Cloudflare quick tunnel (cloudflared, no account) to a proxy on 127.0.0.1 (Proxy). The tunnel
/// carries the app's traffic in the clear to Cloudflare, as any tunnel does; the link's token is the only key.
final class LiveSession: @unchecked Sendable {
    let id: String
    let upstream: Int
    let owner: String
    var trusted: Bool         // guests' items go straight to agents, not to triage
    var privateMode: Bool     // each guest sees only their own items
    let ownerToken = LiveSession.token(), guestToken = LiveSession.token()
    let started = Date()
    let proxy: Proxy
    let room = Room()
    private var tunnel: Tunnel?
    private(set) var publicURL: String?
    private var watch: Timer?
    /// The app's window: people came or went, or an item moved.
    var onChange: (@Sendable () -> Void)?
    /// A guest asked for something: their name and what they said, a line per request.
    var onRequest: (@Sendable (String, [String]) -> Void)?
    /// The owner ended the link from their browser: whoever started it ends it the same way as its own End.
    var onEnd: (@Sendable () -> Void)?
    var log: @Sendable (String) -> Void = { _ in }

    /// Without a tunnel, the link works on this Mac only (for trying it out).
    var guestLink: String { "\(publicURL ?? "http://127.0.0.1:\(proxy.port)")/__pay/k/\(guestToken)" }
    var ownerLink: String { "http://127.0.0.1:\(proxy.port)/__pay/k/\(ownerToken)" }

    init(upstream: Int, owner: String, trusted: Bool = false, privateMode: Bool = false) {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HHmmss"
        id = "live-\(f.string(from: Date()))"
        self.upstream = upstream
        self.owner = Author(name: owner, via: "").name
        self.trusted = trusted
        self.privateMode = privateMode
        proxy = Proxy(upstream: upstream)
        proxy.role = { [ownerToken, guestToken] t in t == ownerToken ? "owner" : t == guestToken ? "guest" : nil }
        proxy.api = { [weak self] head, w, role in
            guard let self else { return await Proxy.respond(w, 404, "text/plain", Data()) }
            await self.api(head, w, role)
        }
    }

    static func token() -> String {
        var b = [UInt8](repeating: 0, count: 18)
        _ = SecRandomCopyBytes(kSecRandomDefault, b.count, &b)
        return Links.b64url(Data(b))
    }

    /// Starts the proxy and, unless `tunnel` is false, the public link. Throws when cloudflared is missing.
    func start(tunnel useTunnel: Bool = true) async throws {
        _ = try proxy.start()
        try? FileManager.default.createDirectory(at: Live.dir, withIntermediateDirectories: true)
        let rec: [String: Any] = ["id": id, "upstream": upstream, "owner": owner, "started": ISO8601DateFormatter().string(from: started)]
        try? JSONSerialization.data(withJSONObject: rec).write(to: Live.dir.appendingPathComponent("\(id).json"))
        if useTunnel {
            let t = Tunnel()
            publicURL = try await t.start(port: proxy.port)
            tunnel = t
        }
        // The queue moves in other processes (agents mark items done): what the room sees is read again every second.
        await MainActor.run {
            watch = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self else { return }
                Task { if await self.room.refresh(self) { self.onChange?() } }
            }
        }
    }

    func stop() {
        watch?.invalidate()
        tunnel?.stop()
        proxy.stop()
        Task { await room.closeAll() }
        try? Live.summary(id).write(to: Live.dir.appendingPathComponent("\(id).md"), atomically: true, encoding: .utf8)
    }

    // MARK: The bar's requests

    func api(_ head: HTTPHead, _ w: Wire, _ role: String) async {
        let guest = head.cookie("__pay_g") ?? "owner"
        switch (head.method, head.path) {
        case ("GET", "/__pay/ws"):
            guard await WebSocket.handshake(head, w) else { return await Proxy.respond(w, 400, "text/plain", Data()) }
            await room.serve(w, guest: guest, role: role, live: self)
        case ("POST", "/__pay/api/rec"):
            guard let n = Int(head.get("Content-Length") ?? ""), n > 0, n < 80 << 20 else {
                return await Proxy.respond(w, 413, "text/plain", Data("too big".utf8))
            }
            let body = await w.read(exactly: n)
            guard let rec = try? JSONDecoder().decode(LiveRecording.self, from: body) else {
                return await Proxy.json(w, ["ok": false, "error": "not a recording"], status: 400)
            }
            let dir = Live.claim()
            await room.track(dir, guest: guest, name: role == "owner" ? owner : Author(name: rec.name, via: "").name, private: rec.private == true, anchor: rec.anchor)
            await Proxy.json(w, ["ok": true, "id": "\(dir.lastPathComponent)#1"], status: 202)
            do {
                try await Live.ingest(rec, into: dir, live: self, guest: guest, role: role, followUp: await room.followUp(rec.followUp, guest: guest))
                let got = Items.items(in: dir, state: Items.readState(dir)).items
                if role != "owner", !got.isEmpty { onRequest?(rec.name, got.map(\.title)) }
                log("\(role == "owner" ? "you" : rec.name): \(got.isEmpty ? "nothing heard" : got.map { "\"\($0.title)…\"" }.joined(separator: ", ") + (got[0].status == "triage" ? " (to accept)" : " (queued)"))")
            } catch {
                log("a recording from \(rec.name) was dropped: \(error)")
            }
            _ = await room.refresh(self)
            onChange?()
        case ("POST", "/__pay/api/settings"):
            // The owner changes the link's settings, or ends it, from their own browser.
            let body = await w.read(exactly: min(Int(head.get("Content-Length") ?? "") ?? 0, 4096))
            guard role == "owner", let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                return await Proxy.json(w, ["ok": false], status: 403)
            }
            if obj["end"] as? Bool == true {
                await Proxy.json(w, ["ok": true])
                log("you ended the link from the browser")
                if let onEnd { onEnd() } else { stop() }
                return
            }
            if let t = obj["trusted"] as? Bool { trusted = t }
            if let p = obj["private"] as? Bool { privateMode = p }
            await room.settings(self)
            onChange?()
            await Proxy.json(w, ["ok": true])
        case ("POST", "/__pay/api/accept"):
            // The owner lets a guest's recording into the queue from their own browser.
            let body = await w.read(exactly: min(Int(head.get("Content-Length") ?? "") ?? 0, 4096))
            guard role == "owner", let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let item = obj["id"] as? String,
                  let session = item.split(separator: "#").first, await room.owns(item, guest: nil) else {
                return await Proxy.json(w, ["ok": false], status: 403)
            }
            let dir = Paths.root.appendingPathComponent(String(session))
            let ids = Items.items(in: dir, state: Items.readState(dir)).items.map(\.id)
            let r = Items.set(ids, status: "open", agent: "you", note: nil)
            log("you accepted \(r.changed.joined(separator: ", "))")
            _ = await room.refresh(self)
            onChange?()
            await Proxy.json(w, ["ok": !r.changed.isEmpty])
        case ("POST", "/__pay/api/confirm"):
            let body = await w.read(exactly: min(Int(head.get("Content-Length") ?? "") ?? 0, 4096))
            guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let item = obj["id"] as? String,
                  await room.owns(item, guest: guest) || role == "owner" else {
                return await Proxy.json(w, ["ok": false], status: 403)
            }
            Items.confirm(item)
            log("\(await room.name(of: guest) ?? "you") confirmed \(item)")
            _ = await room.refresh(self)
            onChange?()
            await Proxy.json(w, ["ok": true])
        default:
            await Proxy.respond(w, 404, "text/plain", Data("not found".utf8))
        }
    }
}

/// What a live guest's browser sends after a recording (Resources/live/bar.js).
struct LiveRecording: Decodable {
    var v: Int
    var name: String
    var duration: Double
    var audio: String?        // base64 WAV, 16 kHz mono
    var text: String?         // typed instead
    var `private`: Bool?
    var followUp: String?     // the item id this says "not yet" to
    var points: [P]
    var snaps: [Snap]
    var page: PageIn
    var anchor: Anchor?       // where its first point was, for the pin others see

    struct P: Decodable { var t: Double; var end: Double; var kind: String; var x: Double; var y: Double; var snap: String?; var el: El? }
    struct El: Decodable {
        var tag: String; var role: String?; var text: String?; var label: String?; var value: String?
        var id: String?; var testid: String?; var rect: R?; var sel: String?; var path: [String]?; var comp: [String]?; var src: String?
    }
    struct R: Decodable { var x: Double; var y: Double; var w: Double; var h: Double }
    struct Snap: Decodable { var id: String; var html: String; var w: Double; var h: Double; var sx: Double; var sy: Double; var t: Double; var origin: String? }
    struct PageIn: Decodable { var url: String; var title: String?; var w: Double; var h: Double; var dpr: Double; var browser: String; var errors: [String]? }
    struct Anchor: Codable { var path: String; var sel: String?; var rx: Double?; var ry: Double? }
}

enum Live {
    static var dir: URL { Paths.root.deletingLastPathComponent().appendingPathComponent("live") }

    /// A new session folder, made now so two recordings arriving together never get the same one.
    static func claim() -> URL {
        Items.locked {
            let d = Import.fresh()
            try? FileManager.default.createDirectory(at: d.appendingPathComponent("frames"), withIntermediateDirectories: true)
            return d
        }
    }

    // An agent waiting for items (wait_for_items, --wait) says so every second, so the people in a live review see
    // that someone is there to fix what they ask.
    static var agentsDir: URL { dir.appendingPathComponent("agents") }

    static func listening(_ agent: String) {
        let name = agent.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || "-_. ".unicodeScalars.contains($0) }.prefix(60)
        guard !name.isEmpty else { return }
        try? FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        try? Data().write(to: agentsDir.appendingPathComponent(String(String.UnicodeScalarView(name))))
    }

    /// Agents that waited for items in the last 15 seconds, or are working on one now.
    static func agents() -> [String] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: agentsDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let recent = files.filter { f in
            ((try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { Date().timeIntervalSince($0) < 15 }) ?? false
        }.map(\.lastPathComponent)
        return recent.sorted()
    }

    /// "claude-code" as people read it.
    static func agentName(_ s: String) -> String {
        let known = ["claude-code": "Claude Code", "claude": "Claude", "codex": "Codex", "cursor": "Cursor"]
        return known[s.lowercased()] ?? s
    }

    /// One line, plain, short: page text reaches an agent.
    static func line(_ s: String?, _ max: Int) -> String? {
        guard let s else { return nil }
        let kept = s.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) }
        let t = String(kept).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return t.isEmpty ? nil : String(t.prefix(max))
    }

    /// A recording from the bar as a session folder: the guest's screen redrawn from their page as it was (on this Mac,
    /// from the dev server), the elements they pointed at with source and component, their speech, in triage unless the
    /// link trusts them.
    static func ingest(_ rec: LiveRecording, into dst: URL, live: LiveSession, guest: String, role: String, followUp: FollowUp?) async throws {
        let fm = FileManager.default
        let duration = min(max(rec.duration, 0), 900)
        let localOrigin = "http://localhost:\(live.upstream)"
        let path = URLComponents(string: rec.page.url).map { $0.percentEncodedPath + ($0.percentEncodedQuery.map { "?\($0)" } ?? "") } ?? "/"
        let base = URL(string: localOrigin + (path.isEmpty ? "/" : path)) ?? URL(string: localOrigin)!

        // The screens they pointed on, drawn here: at most 30, each once.
        let used = Array(Set(rec.points.compactMap(\.snap))).sorted()
        var frames: [Frame] = [], names: [String: String] = [:]
        for snap in rec.snaps where used.contains(snap.id) && frames.count < 30 {
            var html = snap.html
            if let o = snap.origin, o.hasPrefix("http") { html = html.replacingOccurrences(of: o, with: localOrigin) }
            guard let img = await Snapshot.render(html: html, base: base, width: snap.w, height: snap.h, scrollX: snap.sx, scrollY: snap.sy) else { continue }
            let file = String(format: "frames/%03d.jpg", frames.count + 1)
            guard Screen.write(img, to: dst.appendingPathComponent(file), quality: 0.8) else { continue }
            frames.append(Frame(file: file, t: round(min(max(snap.t, 0), duration) * 1000) / 1000, display: Rect(CGRect(x: 0, y: 0, width: snap.w, height: snap.h)),
                                scale: Double(img.width) / max(snap.w, 1), reason: "point"))
            names[snap.id] = file
        }

        let browser = line(rec.page.browser, 60) ?? "a browser"
        var points: [PointEvent] = []
        for p in rec.points.prefix(400) where p.kind == "dwell" || p.kind == "click" {
            let e = p.el
            let el = e.map { e in
                Element(role: line(e.role, 40) ?? line(e.tag, 20), subrole: nil, title: line(e.text, 120), label: line(e.label, 120),
                        value: line(e.value, 120), help: nil, identifier: line(e.testid, 80) ?? line(e.id, 80),
                        frame: e.rect.map { Rect(CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h)) },
                        path: (e.path ?? []).prefix(12).compactMap { line($0, 80) },
                        source: line(e.src, 200), component: e.comp.flatMap { $0.isEmpty ? nil : line($0.suffix(6).joined(separator: " > "), 200) },
                        selector: line(e.sel, 200))
            }
            points.append(PointEvent(index: points.count, t: (min(max(p.t, 0), duration) * 1000).rounded() / 1000,
                                     end: (min(max(p.end, p.t), duration) * 1000).rounded() / 1000,
                                     at: Pt(x: p.x.rounded(), y: p.y.rounded()), kind: p.kind, app: browser, bundleID: nil,
                                     window: line(rec.page.title, 120), url: base.absoluteString, element: el, frame: p.snap.flatMap { names[$0] }))
        }
        var events = SessionEvents(started: Date().addingTimeInterval(-duration), duration: (duration * 1000).rounded() / 1000,
                                   samples: [], points: points, frames: frames)
        if role != "owner" { events.author = Author(name: rec.name, via: "live") }
        let dpr = rec.page.dpr > 0 ? String(format: " @%gx", (rec.page.dpr * 10).rounded() / 10) : ""
        events.page = Page(url: base.absoluteString, title: line(rec.page.title, 120), viewport: "\(Int(rec.page.w))×\(Int(rec.page.h))\(dpr)",
                           browser: browser, errors: (rec.page.errors ?? []).suffix(12).compactMap { line($0, 300) })
        events.followUp = followUp

        if let a = rec.audio, let wav = Data(base64Encoded: a), wav.count < 60 << 20,
           wav.prefix(4) == Data("RIFF".utf8), wav.dropFirst(8).prefix(4) == Data("WAVE".utf8) {
            try wav.write(to: dst.appendingPathComponent("audio.wav"))
        } else if let t = rec.text?.prefix(5000), !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try JSONEncoder.pretty.encode(Links.typed(String(t), over: duration)).write(to: dst.appendingPathComponent("transcript.json"))
        }
        try JSONEncoder.pretty.encode(events).write(to: dst.appendingPathComponent("events.json"))
        if events.author != nil, !live.trusted {
            var st = ItemState(source: "session")
            st.items["1"] = .init(status: "triage", by: events.author?.name, at: Date(), note: nil)
            Items.writeState(st, dst)
        }
        let mark: [String: Any] = ["live": live.id, "guest": guest, "private": rec.private == true]
        try? JSONSerialization.data(withJSONObject: mark).write(to: dst.appendingPathComponent("live.json"))
        if fm.fileExists(atPath: dst.path) { _ = await Process.run(dir: dst, log: { _ in }) }
    }

    /// Every recording of a live review, oldest first.
    static func sessions(of id: String) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: Paths.root, includingPropertiesForKeys: nil)) ?? [])
            .filter { d in
                (try? Data(contentsOf: d.appendingPathComponent("live.json")))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["live"] as? String == id
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The words of one request, as said (a recording that asks for several things has a part for each).
    static func said(_ i: Item, _ dir: URL) -> String {
        let words = (try? Data(contentsOf: dir.appendingPathComponent("transcript.json"))).flatMap { try? JSONDecoder().decode([Word].self, from: $0) } ?? []
        var sents = Builder.sentences(words)
        let events = (try? Data(contentsOf: dir.appendingPathComponent("events.json"))).flatMap { try? JSONDecoder.iso.decode(SessionEvents.self, from: $0) }
        _ = Builder.attach(events?.points ?? [], to: &sents)
        let groups = Builder.requests(sents, events?.points ?? [])
        guard i.n - 1 < groups.count else { return words.map(\.text).joined(separator: " ") }
        return groups[i.n - 1].sents.flatMap { sents[$0].words }.map(\.text).joined(separator: " ")
    }

    /// Where a request points on its page, for its pin: the first element it is about, and where on it.
    static func anchor(_ i: Item, _ events: SessionEvents?) -> LiveRecording.Anchor? {
        guard let pts = events?.points else { return nil }
        for idx in i.points where idx < pts.count {
            let p = pts[idx]
            guard let sel = p.element?.selector, let f = p.element?.frame?.cg else { continue }
            let path = p.url.flatMap { URLComponents(string: $0)?.path } ?? "/"
            return .init(path: path.isEmpty ? "/" : path, sel: sel,
                         rx: f.width > 0 ? ((p.at.x - f.minX) / f.width * 1000).rounded() / 1000 : 0.5,
                         ry: f.height > 0 ? ((p.at.y - f.minY) / f.height * 1000).rounded() / 1000 : 0.5)
        }
        return nil
    }

    /// The newest live review's id.
    static func latest() -> String? {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix("live-") && $0.hasSuffix(".json") }.sorted().last.map { String($0.dropLast(5)) }
    }

    /// What a live review produced, for a pull request: who asked for what, where, what the agent did, who checked it.
    static func summary(_ id: String) -> String {
        let info = (try? Data(contentsOf: dir.appendingPathComponent("\(id).json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let rows: [(Item, SessionEvents?, URL)] = sessions(of: id).flatMap { d in
            let e = (try? Data(contentsOf: d.appendingPathComponent("events.json"))).flatMap { try? JSONDecoder.iso.decode(SessionEvents.self, from: $0) }
            return Items.items(in: d, state: Items.readState(d)).items.map { ($0, e, d) }
        }
        var md = "## Live review\(info?["upstream"].map { " of localhost:\($0)" } ?? "")\n\n"
        let people = Array(Set(rows.map { $0.0.author?.name ?? "you" })).sorted()
        md += rows.isEmpty ? "Nothing was asked.\n" : "\(rows.count) request\(rows.count == 1 ? "" : "s") from \(people.joined(separator: ", ")). "
        if !rows.isEmpty {
            let done = rows.filter { $0.0.status == "done" }.count, ok = rows.filter { $0.0.confirmed != nil }.count
            md += "\(done) done, \(ok) checked by the person who asked.\n\n| Item | From | Asked | State |\n| --- | --- | --- | --- |\n"
            for (i, _, _) in rows {
                let state = i.confirmed != nil ? "done, confirmed" : i.status == "triage" ? "not accepted" : i.status.replacingOccurrences(of: "_", with: " ")
                md += "| `\(i.id)` | \(i.author?.name ?? "you") | \(i.title.replacingOccurrences(of: "|", with: "/"))… | \(state)\(i.note.map { ": \($0.replacingOccurrences(of: "|", with: "/"))" } ?? "") |\n"
            }
            md += "\n"
            for (i, e, d) in rows {
                md += "### \(i.author?.name ?? "You"): \(i.title)…\n\n> \(Live.said(i, d))\n\n"
                if let f = e?.followUp { md += "Follow-up to `\(f.id)`.\n" }
                let pts = e?.points ?? []
                for p in i.points.compactMap({ $0 < pts.count ? pts[$0] : nil }).filter({ $0.element?.source != nil || $0.kind == "click" }).prefix(4) { md += "- [\(p.index + 1)] \(Builder.describe(p))\n" }
                if let pg = e?.page { md += "- Seen in \(pg.browser), \(pg.viewport), \(pg.url)\n" }
                if let n = i.note { md += "- Fix (\(i.by ?? "agent")): \(n)\n" }
                if i.confirmed != nil { md += "- \(i.author?.name ?? "You") looked at the fix and said it is right.\n" }
                if let c = i.crops.first { md += "- Crop: `\(c.path)`\n" }
                md += "\n"
            }
        }
        return md
    }
}

extension Items {
    /// The person who asked looked at the fix and said yes.
    static func confirm(_ id: String) {
        locked {
            let parts = id.split(separator: "#")
            guard parts.count == 2, !parts[0].contains("/"), !parts[0].contains("..") else { return }
            let dir = Paths.root.appendingPathComponent(String(parts[0]))
            guard var st = readState(dir), var e = st.items[String(parts[1])] else { return }
            e.confirmed = Date()
            st.items[String(parts[1])] = e
            writeState(st, dir)
        }
    }
}

// MARK: The room

/// Who is in the link right now, their cursors, and the items made in it, sent to each browser as they change.
actor Room {
    struct Peer { var id: String; var guest: String; var name: String; var role: String; var color: String; var wire: Wire; var talking = false }
    struct Tracked { var dir: URL; var guest: String; var name: String?; var priv: Bool; var anchor: LiveRecording.Anchor? }

    private var peers: [String: Peer] = [:]
    private var tracked: [Tracked] = []
    private var last: [String: String] = [:]   // per peer: the items message last sent
    private var anchors: [String: [LiveRecording.Anchor?]] = [:]   // per recording, once written down: each request's pin
    private var said: [String: String] = [:]   // per item: everything said for it
    private var colorIndex = 0
    static let colors = ["#e5484d", "#3e63dd", "#30a46c", "#f76b15", "#8e4ec6", "#12a594", "#d6409f", "#ab6400"]

    var count: Int { peers.count }
    var names: [String] { peers.values.filter { $0.role != "owner" }.map(\.name).sorted() }

    func serve(_ w: Wire, guest: String, role: String, live: LiveSession) async {
        let id = LiveSession.token()
        var me = Peer(id: id, guest: guest, name: role == "owner" ? live.owner : "Guest", role: role, color: Self.colors[colorIndex % Self.colors.count], wire: w)
        colorIndex += 1
        peers[id] = me
        send(id, ["t": "welcome", "you": ["id": id, "role": role, "color": me.color], "owner": live.owner,
                  "private": live.privateMode, "trusted": live.trusted || role == "owner", "settings": ["trusted": live.trusted],
                  "link": role == "owner" ? live.guestLink : ""])
        await WebSocket.read(w) { text in
            guard let data = text.data(using: .utf8), let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            await self.handle(msg, from: id, live: live)
        }
        me = peers[id] ?? me
        peers[id] = nil
        last[id] = nil
        w.c.cancel()
        broadcastPeers()
        if me.role != "owner" { live.log("\(me.name) left") }
        live.onChange?()
    }

    private func handle(_ msg: [String: Any], from id: String, live: LiveSession) {
        guard var p = peers[id] else { return }
        switch msg["t"] as? String {
        case "hello":
            let first = p.name == "Guest"
            if p.role != "owner", let n = msg["name"] as? String { p.name = Author(name: n, via: "").name }
            peers[id] = p
            broadcastPeers()
            if first, p.role != "owner" { live.log("\(p.name) joined") }
            send(id, items(for: p))
            live.onChange?()
        case "cursor":
            var out: [String: Any] = ["t": "cursor", "id": id, "name": p.name, "color": p.color]
            for k in ["path", "sel", "rx", "ry", "x", "y", "vw", "vh", "gone"] { if let v = msg[k] { out[k] = v } }
            for q in peers.values where q.id != id { send(q.id, out) }
        case "talking":
            p.talking = msg["on"] as? Bool ?? false
            peers[id] = p
            broadcastPeers()
        default: break
        }
    }

    private func broadcastPeers() {
        let list = peers.values.sorted { $0.id < $1.id }.map { ["id": $0.id, "name": $0.name, "color": $0.color, "role": $0.role, "talking": $0.talking] as [String: Any] }
        for q in peers.values { send(q.id, ["t": "peers", "peers": list]) }
    }

    private func send(_ id: String, _ obj: [String: Any]) {
        guard let w = peers[id]?.wire, let data = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: data, encoding: .utf8) else { return }
        Task { await w.write(WebSocket.frame(s)) }
    }

    /// The owner changed a setting: everyone in the link hears it now, not only those who join after.
    func settings(_ live: LiveSession) {
        for q in peers.values { send(q.id, ["t": "settings", "private": live.privateMode, "trusted": live.trusted || q.role == "owner", "settings": ["trusted": live.trusted]]) }
    }

    func closeAll() {
        let ended = WebSocket.frame(#"{"t":"ended"}"#)
        for p in peers.values { Task { await p.wire.write(ended); await p.wire.write(Data([0x88, 0])); p.wire.c.cancel() } }
    }

    func track(_ dir: URL, guest: String, name: String?, private priv: Bool, anchor: LiveRecording.Anchor?) {
        tracked.append(Tracked(dir: dir, guest: guest, name: name, priv: priv, anchor: anchor))
        refreshNow()
    }

    /// Whether the item was asked in this link (by `guest`, when given).
    func owns(_ item: String, guest: String?) -> Bool {
        tracked.contains { item.hasPrefix("\($0.dir.lastPathComponent)#") && (guest == nil || $0.guest == guest) }
    }

    func name(of guest: String) -> String? { peers.values.first { $0.guest == guest }?.name }

    /// "Not yet" on an item this guest asked for: what it was, and what the agent said it did.
    func followUp(_ item: String?, guest: String) -> FollowUp? {
        guard let item, let t = tracked.first(where: { item.hasPrefix("\($0.dir.lastPathComponent)#") && ($0.guest == guest || guest == "owner") }),
              let i = Items.items(in: t.dir, state: Items.readState(t.dir)).items.first(where: { $0.id == item }) else { return nil }
        return FollowUp(id: i.id, said: i.title, note: i.note, by: i.by)
    }

    /// Sends each peer the items it may see when they changed. True when anything did.
    func refresh(_ live: LiveSession) -> Bool { refreshNow() }

    private(set) var agents: [String] = []

    @discardableResult
    private func refreshNow() -> Bool {
        let now = Live.agents().map(Live.agentName)
        var changed = now != agents
        agents = now
        for p in peers.values {
            let msg = items(for: p)
            guard let data = try? JSONSerialization.data(withJSONObject: msg, options: [.sortedKeys]), let s = String(data: data, encoding: .utf8) else { continue }
            if last[p.id] != s { last[p.id] = s; send(p.id, msg); changed = true }
        }
        return changed
    }

    private static func json(_ a: LiveRecording.Anchor) -> [String: Any] { ["path": a.path, "sel": a.sel as Any, "rx": a.rx as Any, "ry": a.ry as Any] }

    /// The room's queue as one browser may see it: the owner sees everything, a guest their own and, unless the link is
    /// private, everyone's that was not marked private.
    private func items(for p: Peer) -> [String: Any] {
        let list: [[String: Any]] = tracked.flatMap { t -> [[String: Any]] in
            let mine = t.guest == p.guest
            guard p.role == "owner" || mine || !t.priv else { return [] }
            let base: [String: Any] = ["mine": mine, "private": t.priv, "from": t.name ?? "you", "rec": t.dir.lastPathComponent]
            let items = Items.items(in: t.dir, state: Items.readState(t.dir)).items
            guard !items.isEmpty else {
                let processed = FileManager.default.fileExists(atPath: t.dir.appendingPathComponent("session.md").path)
                var o = base
                o["id"] = "\(t.dir.lastPathComponent)#1"
                o["status"] = processed ? "empty" : "processing"
                if let a = t.anchor { o["anchor"] = Self.json(a) }
                return [o]
            }
            let events = anchors[t.dir.lastPathComponent] == nil
                ? (try? Data(contentsOf: t.dir.appendingPathComponent("events.json"))).flatMap { try? JSONDecoder.iso.decode(SessionEvents.self, from: $0) }
                : nil
            if anchors[t.dir.lastPathComponent] == nil {
                anchors[t.dir.lastPathComponent] = items.map { Live.anchor($0, events) ?? ($0.n == 1 ? t.anchor : nil) }
            }
            let marks = anchors[t.dir.lastPathComponent] ?? []
            for i in items where said[i.id] == nil { said[i.id] = Live.said(i, t.dir) }
            return items.map { item in
                var o = base
                o["id"] = item.id
                o["title"] = item.title
                o["said"] = said[item.id] ?? item.title
                o["status"] = item.status
                if items.count > 1 { o["part"] = "\(item.n) of \(items.count)" }
                if let by = item.by, item.status == "in_progress" || item.status == "done" { o["by"] = Live.agentName(by) }
                if let n = item.note, item.status == "done" { o["note"] = n }
                if item.confirmed != nil { o["confirmed"] = true }
                if item.n - 1 < marks.count, let a = marks[item.n - 1] { o["anchor"] = Self.json(a) }
                return o
            }
        }
        return ["t": "items", "items": list, "agents": agents]
    }
}

// MARK: The tunnel

/// A free Cloudflare quick tunnel (`cloudflared tunnel --url`), no account: a random https://…trycloudflare.com address
/// to a port on this Mac, for as long as it runs.
final class Tunnel: @unchecked Sendable {
    private let p = Foundation.Process()

    static func binary() -> String? {
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return (["/opt/homebrew/bin", "/usr/local/bin"] + path).map { "\($0)/cloudflared" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The public address, once Cloudflare has a connection for it (and it answers), or an error after 40 s.
    func start(port: Int) async throws -> String {
        guard let bin = Self.binary() else {
            throw Links.Failure.refused("cloudflared is not installed. It is free and needs no account: brew install cloudflared")
        }
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["tunnel", "--no-autoupdate", "--url", "http://127.0.0.1:\(port)"]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        let found = Found()
        err.fileHandleForReading.readabilityHandler = { h in
            let s = String(decoding: h.availableData, as: UTF8.self)
            if let r = s.range(of: #"https://[a-z0-9-]+\.trycloudflare\.com"#, options: .regularExpression) { found.url(String(s[r])) }
            if s.contains("Registered tunnel connection") { found.registered() }
        }
        try p.run()
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline {
            if let u = found.ready {
                // The name takes a moment to resolve: the link is shown once it answers.
                for _ in 0..<20 {
                    var req = URLRequest(url: URL(string: "\(u)/__pay/bar.js")!); req.timeoutInterval = 4
                    if let (_, r) = try? await URLSession.shared.data(for: req), (r as? HTTPURLResponse)?.statusCode == 200 { break }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                return u
            }
            if !p.isRunning { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        stop()
        throw Links.Failure.refused("the tunnel did not come up (is this Mac online?)")
    }

    func stop() { if p.isRunning { p.terminate() } }

    private final class Found: @unchecked Sendable {
        private let lock = NSLock()
        private var u: String?, reg = false
        func url(_ s: String) { lock.lock(); if u == nil { u = s }; lock.unlock() }
        func registered() { lock.lock(); reg = true; lock.unlock() }
        var ready: String? { lock.lock(); defer { lock.unlock() }; return reg ? u : nil }
    }
}

/// The review bar's script: Resources/live/bar.js, in the app bundle or (a build from the source tree) next to the sources.
enum LiveAssets {
    static var bar: Data {
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent("live/bar.js"),
                          URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                            .appendingPathComponent("Resources/live/bar.js")]
        for c in candidates.compactMap({ $0 }) { if let d = try? Data(contentsOf: c) { return d } }
        return Data("console.warn('Point and Yap: the review bar is missing from this build')".utf8)
    }
}

/// Dev servers listening on this Mac, for the window's port menu: port and the program, from lsof.
enum DevServers {
    static func find() -> [(port: Int, name: String)] {
        let p = Foundation.Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fcn"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        var found: [Int: String] = [:], cmd = ""
        let skip = ["PointAndYap", "cloudflared", "workerd", "ControlCe", "rapportd", "Spotify", "Dropbox", "figma_age", "Code\\x20H", "Cursor", "Electron", "Google"]
        for l in text.split(separator: "\n") {
            if l.hasPrefix("c") { cmd = String(l.dropFirst()) }
            else if l.hasPrefix("n"), let port = l.split(separator: ":").last.flatMap({ Int($0) }), port >= 1024, port < 49152,
                    !skip.contains(where: { cmd.hasPrefix($0) }) { found[port] = cmd }
        }
        return found.map { ($0.key, $0.value) }.sorted { $0.port < $1.port }
    }
}

/// `PointAndYap --live <port> [--from <name>] [--trust] [--private] [--no-tunnel] [--open]`: until Ctrl-C.
enum LiveCLI {
    static func run(_ args: [String]) {
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        guard let port = value("--live").flatMap({ Int($0) }), port > 0, port < 65536 else {
            print("Usage: PointAndYap --live <port of your dev server> [--from <your name>] [--trust] [--private] [--no-tunnel] [--open]")
            exit(2)
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        let name = value("--from") ?? Join.myName
        let live = LiveSession(upstream: port, owner: name, trusted: args.contains("--trust"), privateMode: args.contains("--private"))
        live.log = { print("· \($0)") }
        NSApplication.shared.setActivationPolicy(.prohibited)   // WebKit draws the guests' screens
        signal(SIGINT, SIG_IGN)
        let sig = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        let end: @Sendable () -> Void = {
            DispatchQueue.main.async {
                live.stop()
                print("\nEnded. The link no longer opens.\n")
                print(Live.summary(live.id))
                print("Saved: \(Live.dir.appendingPathComponent("\(live.id).md").path)")
                // A moment for the guests' "ended" to go out.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
            }
        }
        live.onEnd = end
        sig.setEventHandler { end() }
        sig.resume()
        Task {
            do {
                print("Starting the link to localhost:\(port)…")
                try await live.start(tunnel: !args.contains("--no-tunnel"))
                print("""

                Live: your app on localhost:\(port), for anyone with this link. They use it in their browser and point and talk:
                \(live.guestLink)\(live.publicURL == nil ? "   (no tunnel: this Mac only)" : "")

                You, in your own browser: \(live.ownerLink)
                \(live.trusted ? "Their recordings go straight to your agents." : "Their recordings wait for you: Accept in the window, or \(QueueCLI.binary) --accept <id>. --trust sends them straight to your agents.")
                Live fixes: ask your agent to "work through Point and Yap live" (the pointandyap MCP wait_for_items).
                Ctrl-C ends the link.

                """)
                if args.contains("--open"), let u = URL(string: live.ownerLink) { NSWorkspace.shared.open(u) }
            } catch {
                print("Could not start: \(error)")
                exit(1)
            }
        }
        NSApp.run()
    }
}
