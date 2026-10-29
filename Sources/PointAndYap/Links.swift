import AppKit
import CryptoKit
import Foundation

/// Review links: `PointAndYap --share <session>` sends a recording's screenshots to a relay, encrypted, and gives a link;
/// whoever opens it points and talks on them in a browser; `PointAndYap --pull` brings what they sent back as sessions
/// with their name on it, waiting in triage until the user accepts them.
///
/// The relay holds only ciphertext. The link key is in the link's #fragment, which browsers never send to a server; it
/// opens the screenshots. What a guest sends is sealed to this Mac's own key (P-256, one per link), so neither the relay
/// nor anyone else with the link can read it.
struct LinkRecord: Codable {
    var id: String
    var relay: String
    var token: String         // the owner's bearer token at the relay
    var key: String           // link key, base64url
    var privateKey: String    // this Mac's P-256 key for this link, base64
    var session: String       // the recording shared
    var frames: [String]      // the frames shared, frames/NNN.jpg
    var created: Date
    var url: String
}

/// What a guest sends from the review page (relay/public/review.js), after it is opened.
struct Feedback: Decodable {
    var v: Int
    var name: String
    var duration: Double
    var samples: [S]
    var points: [P]
    var audio: String?        // base64 WAV, 16 kHz mono
    var text: String?         // typed instead of said
    struct S: Decodable { var t: Double; var f: String; var x: Double; var y: Double; var down: Bool }
    struct P: Decodable { var t: Double; var end: Double; var kind: String; var f: String; var x: Double; var y: Double }
}

/// A recording a guest made in Point and Yap and sent to a link they joined: its files, base64.
struct Recording: Codable {
    var v = 1
    var kind = "recording"
    var name: String
    var files: [String: String]
}

enum Links {
    enum Failure: Error, CustomStringConvertible {
        case refused(String)
        var description: String { if case .refused(let s) = self { return s }; return "" }
    }

    static let dir = ProcessInfo.processInfo.environment["POINTANDYAP_LINKS"].map { URL(fileURLWithPath: $0) }
        ?? Paths.support.appendingPathComponent("links")

    /// The relay: --relay, POINTANDYAP_RELAY, or `defaults write com.marcmaurer.pointandyap relay <url>`.
    static func relay(_ arg: String? = nil) -> URL? {
        (arg ?? ProcessInfo.processInfo.environment["POINTANDYAP_RELAY"] ?? UserDefaults.standard.string(forKey: "relay"))
            .flatMap { URL(string: $0.hasSuffix("/") ? String($0.dropLast()) : $0) }
    }

    // MARK: Sharing

    /// Shares a recording's screenshots and returns the link to send.
    /// Only screenshots go: what the user said in the recording stays here unless they give a title.
    static func share(_ session: URL, relay: URL, from owner: String?, title: String? = nil) async throws -> LinkRecord {
        guard let data = try? Data(contentsOf: session.appendingPathComponent("events.json")),
              let events = try? JSONDecoder.iso.decode(SessionEvents.self, from: data) else {
            throw Failure.refused("\(session.lastPathComponent) is not a recording")
        }
        let frames = pick(events)
        guard !frames.isEmpty else { throw Failure.refused("\(session.lastPathComponent) has no screenshots to share") }
        let key = SymmetricKey(size: .bits256)
        let mine = P256.KeyAgreement.PrivateKey()
        var tourFrames: [[String: Any]] = []
        for f in frames {
            guard let (jpeg, w, h) = downscaled(session.appendingPathComponent(f.file)) else { continue }
            tourFrames.append(["name": f.file, "w": w, "h": h, "jpeg": jpeg.base64EncodedString()])
        }

        let created = try await call(relay, "POST", "/api/links", token: nil, body: nil)
        guard let obj = try? JSONSerialization.jsonObject(with: created) as? [String: Any],
              let id = obj["id"] as? String, let token = obj["token"] as? String else { throw Failure.refused("the relay did not make a link") }
        var tour: [String: Any] = ["v": 1, "id": id, "key": mine.publicKey.x963Representation.base64EncodedString(), "frames": tourFrames]
        if let title, !title.isEmpty { tour["title"] = String(title.prefix(120)) }
        if let owner, !owner.isEmpty { tour["from"] = Author(name: owner, via: "").name }
        let plain = try JSONSerialization.data(withJSONObject: tour)
        _ = try await call(relay, "PUT", "/api/links/\(id)/tour", token: token, body: try sealTour(plain, key: key, id: id))

        let keyData = key.withUnsafeBytes { Data($0) }
        let record = LinkRecord(id: id, relay: relay.absoluteString, token: token, key: b64url(keyData),
                                privateKey: mine.rawRepresentation.base64EncodedString(), session: session.lastPathComponent,
                                frames: tourFrames.compactMap { $0["name"] as? String }, created: Date(),
                                url: "\(relay.absoluteString)/r/\(id)#k=\(b64url(keyData))")
        try save(record)
        return record
    }

    /// The screenshots worth showing: every one when there are few, else the start and each one pointed at.
    static func pick(_ e: SessionEvents) -> [Frame] {
        if e.frames.count <= 24 { return e.frames }
        let pointed = Set(e.points.compactMap(\.frame))
        return Array(e.frames.filter { $0.reason == "start" || pointed.contains($0.file) }.prefix(24))
    }

    /// A frame as a JPEG at most 1600 px wide, for the page.
    static func downscaled(_ url: URL) -> (Data, Int, Int)? {
        guard let img = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = min(1600, img.width), h = img.height * w / img.width
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage(),
              let data = NSBitmapImageRep(cgImage: out).representation(using: .jpeg, properties: [.compressionFactor: 0.72])
        else { return nil }
        return (data, w, h)
    }

    /// An invite: a link with no screenshots. A guest with Point and Yap joins it, and their recordings come here.
    static func invite(relay: URL, from owner: String?) async throws -> LinkRecord {
        let key = SymmetricKey(size: .bits256)
        let mine = P256.KeyAgreement.PrivateKey()
        let created = try await call(relay, "POST", "/api/links", token: nil, body: nil)
        guard let obj = try? JSONSerialization.jsonObject(with: created) as? [String: Any],
              let id = obj["id"] as? String, let token = obj["token"] as? String else { throw Failure.refused("the relay did not make a link") }
        var tour: [String: Any] = ["v": 1, "id": id, "key": mine.publicKey.x963Representation.base64EncodedString(), "frames": [], "invite": true]
        if let owner, !owner.isEmpty { tour["from"] = Author(name: owner, via: "").name }
        _ = try await call(relay, "PUT", "/api/links/\(id)/tour", token: token, body: try sealTour(try JSONSerialization.data(withJSONObject: tour), key: key, id: id))
        let keyData = key.withUnsafeBytes { Data($0) }
        let record = LinkRecord(id: id, relay: relay.absoluteString, token: token, key: b64url(keyData),
                                privateKey: mine.rawRepresentation.base64EncodedString(), session: "", frames: [], created: Date(),
                                url: "\(relay.absoluteString)/r/\(id)#k=\(b64url(keyData))")
        try save(record)
        return record
    }

    // MARK: Pulling

    /// Fetches what guests sent to every link, turns each into a session in triage, and deletes it from the relay.
    @discardableResult
    static func pull(log: (String) -> Void = { _ in }) async -> [URL] {
        var out: [URL] = []
        for link in all() {
            guard let relay = URL(string: link.relay) else { continue }
            let list: [String]
            do {
                let data = try await call(relay, "GET", "/api/links/\(link.id)/feedback", token: link.token, body: nil)
                list = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["items"] as? [[String: Any]] ?? [])
                    .compactMap { $0["id"] as? String }
            } catch {
                log("\(link.id): \(error)")
                continue
            }
            for fid in list {
                do {
                    let blob = try await call(relay, "GET", "/api/links/\(link.id)/feedback/\(fid)", token: link.token, body: nil)
                    let plain = try open(blob, link: link)
                    let dir: URL
                    if let rec = try? JSONDecoder().decode(Recording.self, from: plain), rec.kind == "recording" {
                        dir = try await received(rec, link: link)
                    } else {
                        dir = try session(from: try JSONDecoder().decode(Feedback.self, from: plain), link: link)
                        _ = await Process.run(dir: dir, log: log)
                    }
                    out.append(dir)
                    log("\(link.id): \(dir.lastPathComponent) from \(Items.items(in: dir, state: nil).items.first?.author?.name ?? "a guest")")
                } catch {
                    // Not ours or not well formed: nothing to keep.
                    log("\(link.id)/\(fid): dropped, \(error)")
                }
                _ = try? await call(relay, "DELETE", "/api/links/\(link.id)/feedback/\(fid)", token: link.token, body: nil)
            }
        }
        return out
    }

    /// A recording a guest made with Point and Yap on their own Mac (Join.send): its files go through the same checks as
    /// --import, and it waits in triage from before it is listed.
    static func received(_ rec: Recording, link: LinkRecord) async throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pointandyap-recv-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("frames"), withIntermediateDirectories: true)
        for (path, b64) in rec.files where path == "events.json" || path == "transcript.json" || Import.frameName(path) {
            guard let data = Data(base64Encoded: b64) else { continue }
            try data.write(to: tmp.appendingPathComponent(path))
        }
        return try await Import.run(tmp, author: rec.name, via: "link", triage: true)
    }

    /// A guest's feedback as a session folder: the shared screenshots (full size, from the recording here), the guest's
    /// pointer in screen points, the element under it where this Mac knows one, their audio or text, in triage.
    static func session(from fb: Feedback, link: LinkRecord) throws -> URL {
        let src = Paths.root.appendingPathComponent(link.session)
        guard let data = try? Data(contentsOf: src.appendingPathComponent("events.json")),
              let owner = try? JSONDecoder.iso.decode(SessionEvents.self, from: data) else {
            throw Failure.refused("the shared recording \(link.session) is gone")
        }
        let shared = Set(link.frames)
        let byName = Dictionary(owner.frames.map { ($0.file, $0) }, uniquingKeysWith: { a, _ in a })
        let duration = min(max(fb.duration, 0), 900)
        func at(_ f: String, _ x: Double, _ y: Double) -> Pt? {
            guard shared.contains(f), let d = byName[f]?.display else { return nil }
            return Pt(x: round1(d.x + min(max(x, 0), 1) * d.w), y: round1(d.y + min(max(y, 0), 1) * d.h))
        }
        var points: [PointEvent] = []
        for p in fb.points.prefix(400) where p.kind == "dwell" || p.kind == "click" {
            guard let pt = at(p.f, p.x, p.y) else { continue }
            let mine = known(at: pt, frame: p.f, in: owner)
            points.append(PointEvent(index: points.count, t: round3(min(max(p.t, 0), duration)), end: round3(min(max(p.end, p.t), duration)),
                                     at: pt, kind: p.kind, app: mine?.app, bundleID: mine?.bundleID, window: mine?.window,
                                     url: mine?.url, element: mine?.element, frame: p.f))
        }
        let samples = fb.samples.prefix(30 * 900).compactMap { s in at(s.f, s.x, s.y).map { Sample(t: round3(s.t), x: $0.x, y: $0.y, down: s.down) } }
        let used = Set(points.compactMap(\.frame))
        var events = SessionEvents(started: Date().addingTimeInterval(-duration), duration: round3(duration), samples: Array(samples),
                                   points: points, frames: owner.frames.filter { used.contains($0.file) })
        events.author = Author(name: fb.name, via: "link")

        let fm = FileManager.default
        let dst = Import.fresh()
        try fm.createDirectory(at: dst.appendingPathComponent("frames"), withIntermediateDirectories: true)
        for f in used { try? fm.copyItem(at: src.appendingPathComponent(f), to: dst.appendingPathComponent(f)) }
        if let a = fb.audio, let wav = Data(base64Encoded: a), wav.count < 40 << 20,
           wav.prefix(4) == Data("RIFF".utf8), wav.dropFirst(8).prefix(4) == Data("WAVE".utf8) {
            try wav.write(to: dst.appendingPathComponent("audio.wav"))
        } else if let t = fb.text?.prefix(5000), !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try JSONEncoder.pretty.encode(typed(String(t), over: duration)).write(to: dst.appendingPathComponent("transcript.json"))
        }
        try JSONEncoder.pretty.encode(events).write(to: dst.appendingPathComponent("events.json"))
        var st = ItemState(source: "session")
        st.items["1"] = .init(status: "triage", by: events.author?.name, at: Date(), note: nil)
        Items.writeState(st, dst)
        return dst
    }

    /// The element this Mac recorded on that screenshot whose frame holds the point, the smallest if several.
    static func known(at p: Pt, frame: String, in owner: SessionEvents) -> PointEvent? {
        owner.points.filter { $0.frame == frame && ($0.element?.frame?.cg.contains(CGPoint(x: p.x, y: p.y)) ?? false) }
            .min { ($0.element!.frame!.w * $0.element!.frame!.h) < ($1.element!.frame!.w * $1.element!.frame!.h) }
    }

    /// Typed feedback as words spread over the time the guest spent, so pointing still lines up roughly with them.
    static func typed(_ text: String, over duration: Double) -> [Word] {
        let parts = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let step = parts.isEmpty ? 0 : max(duration, Double(parts.count) * 0.3) / Double(parts.count)
        return parts.enumerated().map { i, w in Word(text: w, start: round3(Double(i) * step), end: round3(Double(i) * step + step * 0.9)) }
    }

    // MARK: Crypto (relay/public/seal.js is the other half)

    static func sealTour(_ plain: Data, key: SymmetricKey, id: String) throws -> Data {
        try AES.GCM.seal(plain, using: key, authenticating: Data("pointandyap tour \(id)".utf8)).combined!
    }

    /// Feedback is: the guest's one-time P-256 public key (65 bytes), then AES-GCM (12-byte nonce, ciphertext, tag) under
    /// HKDF-SHA256(ECDH(guest, this Mac), salt: link key, info: "pointandyap feedback <id>"), the public key as AAD.
    static func openFeedback(_ blob: Data, link: LinkRecord) throws -> Feedback {
        try JSONDecoder().decode(Feedback.self, from: try open(blob, link: link))
    }

    static func open(_ blob: Data, link: LinkRecord) throws -> Data {
        guard blob.count > 65 + 12 + 16, let keyData = unb64url(link.key), let raw = Data(base64Encoded: link.privateKey) else {
            throw Failure.refused("too short")
        }
        let mine = try P256.KeyAgreement.PrivateKey(rawRepresentation: raw)
        let epk = Data(blob.prefix(65))
        let shared = try mine.sharedSecretFromKeyAgreement(with: try P256.KeyAgreement.PublicKey(x963Representation: epk))
        let k = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: keyData, sharedInfo: Data("pointandyap feedback \(link.id)".utf8), outputByteCount: 32)
        return try AES.GCM.open(try AES.GCM.SealedBox(combined: Data(blob.dropFirst(65))), using: k, authenticating: epk)
    }

    static func openTour(_ blob: Data, key: Data, id: String) throws -> Data {
        try AES.GCM.open(try AES.GCM.SealedBox(combined: blob), using: SymmetricKey(data: key), authenticating: Data("pointandyap tour \(id)".utf8))
    }

    /// What the page does, for tests.
    static func sealFeedback(_ plain: Data, to owner: P256.KeyAgreement.PublicKey, linkKey: Data, id: String) throws -> Data {
        let eph = P256.KeyAgreement.PrivateKey()
        let epk = eph.publicKey.x963Representation
        let k = try eph.sharedSecretFromKeyAgreement(with: owner)
            .hkdfDerivedSymmetricKey(using: SHA256.self, salt: linkKey, sharedInfo: Data("pointandyap feedback \(id)".utf8), outputByteCount: 32)
        return epk + (try AES.GCM.seal(plain, using: k, authenticating: epk).combined!)
    }

    static func b64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func unb64url(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b)
    }

    // MARK: Records and the relay

    static func all() -> [LinkRecord] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .compactMap { (try? Data(contentsOf: $0)).flatMap { try? JSONDecoder.iso.decode(LinkRecord.self, from: $0) } }
            .sorted { $0.created < $1.created }
    }

    /// Readable only by the user: it holds the keys that open what guests send.
    static func save(_ r: LinkRecord) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = dir.appendingPathComponent("\(r.id).json")
        try JSONEncoder.pretty.encode(r).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Deletes the link at the relay (with everything not yet pulled) and its keys here.
    static func revoke(_ id: String) async throws {
        guard let r = all().first(where: { $0.id == id }), let relay = URL(string: r.relay) else { throw Failure.refused("no link \(id)") }
        _ = try await call(relay, "DELETE", "/api/links/\(id)", token: r.token, body: nil)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).json"))
    }

    static func call(_ relay: URL, _ method: String, _ path: String, token: String?, body: Data?) async throws -> Data {
        var req = URLRequest(url: URL(string: relay.absoluteString + path)!)
        req.httpMethod = method
        req.timeoutInterval = 60
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { req.httpBody = body; req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw Failure.refused("relay \(method) \(path): \(code) \(String(decoding: data.prefix(200), as: UTF8.self))") }
        return data
    }
}

/// `PointAndYap --share [<session>] [--relay <url>] [--from <name>] [--title <text>]`, `--invite [--from <name>]`, `--pull`,
/// `--links`, `--revoke <id>`, `--accept <item id>...`; a guest: `--join <link> [--as <name>]`, `--send [<session>]`, `--leave`.
enum LinksCLI {
    static func run(_ args: [String]) {
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var code: Int32 = 0
        Task.detached {
            do {
                if args.contains("--share") {
                    guard let relay = Links.relay(value("--relay")) else {
                        throw Links.Failure.refused("no relay: --relay <url>, POINTANDYAP_RELAY, or defaults write com.marcmaurer.pointandyap relay <url>")
                    }
                    let name = value("--share").flatMap { $0.hasPrefix("--") ? nil : $0 }
                    guard let session = MCPServer.dir(name) else { throw Links.Failure.refused("no recording \(name ?? "yet")") }
                    let r = try await Links.share(session, relay: relay, from: value("--from"), title: value("--title"))
                    print("Link for \(r.session) (\(r.frames.count) screenshot\(r.frames.count == 1 ? "" : "s")); anyone with it can point and talk on them:\n\(r.url)")
                } else if args.contains("--invite") {
                    guard let relay = Links.relay(value("--relay")) else { throw Links.Failure.refused("no relay: --relay <url> or POINTANDYAP_RELAY") }
                    let r = try await Links.invite(relay: relay, from: value("--from"))
                    print("Invite. Whoever joins it with Point and Yap sends you their recordings:\n\(r.url)")
                } else if let link = value("--join") {
                    let j = try await Join.lookup(link)
                    try Join.join(j)
                    if let name = value("--as") { UserDefaults.standard.set(name, forKey: "shareName") }
                    print("Joined: your recordings now go to \(j.to), not to your own agents. \(QueueCLI.binary) --leave stops it.")
                } else if args.contains("--leave") {
                    Join.leave()
                    print("Left. Recordings stay here again.")
                } else if args.contains("--send") {
                    guard let j = Join.current() else { throw Links.Failure.refused("not joined to anyone: --join <link>") }
                    let name = value("--send").flatMap { $0.hasPrefix("--") ? nil : $0 }
                    guard let dir = MCPServer.dir(name) else { throw Links.Failure.refused("no recording \(name ?? "yet")") }
                    try await Join.send(dir, to: j, as: value("--as") ?? Join.myName)
                    print("Sent \(dir.lastPathComponent) to \(j.to).")
                } else if args.contains("--pull") {
                    let got = await Links.pull { print("pointandyap: \($0)") }
                    print(got.isEmpty ? "Nothing new from review links." : "\(got.count) new, waiting for you in triage: \(QueueCLI.binary) --accept <id>")
                } else if args.contains("--links") {
                    let all = Links.all()
                    print(all.isEmpty ? "No review links." : all.map { "- \($0.id): \($0.session), \($0.url)" }.joined(separator: "\n"))
                } else if let id = value("--revoke") {
                    try await Links.revoke(id)
                    print("Revoked \(id).")
                } else if args.contains("--accept") {
                    let ids = args.drop { $0 != "--accept" }.dropFirst().filter { !$0.hasPrefix("--") }
                    let r = Items.set(Array(ids), status: "open", agent: "you", note: nil)
                    if !r.changed.isEmpty { print("In the queue: \(r.changed.joined(separator: ", "))") }
                    if !r.missing.isEmpty { print("Not changed: \(r.missing.joined(separator: ", "))"); code = 1 }
                }
            } catch {
                print("\(error)")
                code = 1
            }
            done.signal()
        }
        done.wait()
        if code != 0 { exit(code) }
    }
}
