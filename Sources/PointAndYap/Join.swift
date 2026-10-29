import AppKit
import CryptoKit
import Foundation

/// The guest's side of an invite: after Join, each recording made here goes to the person who sent the link, sealed to
/// their Mac, instead of to this Mac's own agents. Leave stops it.
struct JoinRecord: Codable, Equatable {
    var id: String
    var relay: String
    var key: String           // the link key, base64url
    var ownerKey: String      // their Mac's P-256 key for this link, base64
    var from: String?         // their name, as they gave it
    var joined: Date?

    var to: String { from ?? "the person who invited you" }
}

enum Join {
    static var file: URL { Links.dir.appendingPathComponent("joined.json") }

    static func current() -> JoinRecord? {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder.iso.decode(JoinRecord.self, from: $0) }
    }

    /// Reads a link (`<relay>/r/<id>#k=<key>`, or `pointandyap://join?link=<that>`): opens its screenshots page to learn
    /// whose it is and their key. Joins nothing yet.
    static func lookup(_ text: String) async throws -> JoinRecord {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let u = URLComponents(string: s), u.scheme == "pointandyap", let inner = u.queryItems?.first(where: { $0.name == "link" })?.value { s = inner }
        guard let u = URLComponents(string: s), let scheme = u.scheme, ["http", "https"].contains(scheme), let host = u.host,
              let r = u.path.range(of: "/r/"), let k = u.fragment?.split(separator: "&").first(where: { $0.hasPrefix("k=") })?.dropFirst(2),
              let key = Links.unb64url(String(k)) else {
            throw Links.Failure.refused("not a Point and Yap link")
        }
        let id = String(u.path[r.upperBound...])
        let relay = "\(scheme)://\(host)\(u.port.map { ":\($0)" } ?? "")\(u.path[..<r.lowerBound])"
        guard let relayURL = URL(string: relay) else { throw Links.Failure.refused("not a Point and Yap link") }
        let blob = try await Links.call(relayURL, "GET", "/api/links/\(id)/tour", token: nil, body: nil)
        guard let tour = try? JSONSerialization.jsonObject(with: try Links.openTour(blob, key: key, id: id)) as? [String: Any],
              let owner = tour["key"] as? String else { throw Links.Failure.refused("the link does not open") }
        return JoinRecord(id: id, relay: relay, key: Links.b64url(key), ownerKey: owner,
                          from: (tour["from"] as? String).map { Author(name: $0, via: "").name }, joined: nil)
    }

    static func join(_ j: JoinRecord) throws {
        var j = j
        j.joined = Date()
        try FileManager.default.createDirectory(at: Links.dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder.pretty.encode(j).write(to: file, options: .atomic)
    }

    static func leave() { try? FileManager.default.removeItem(at: file) }

    /// The name guests send under: `defaults write com.marcmaurer.pointandyap shareName <name>`, else the first name.
    static var myName: String {
        UserDefaults.standard.string(forKey: "shareName") ?? NSFullUserName().split(separator: " ").first.map(String.init) ?? "A guest"
    }

    /// While joined, a new recording waits as "sending", so this Mac's agents never take it.
    static func hold(_ dir: URL, for j: JoinRecord) {
        var st = ItemState(source: "session")
        st.items["1"] = .init(status: "triage", by: "sending to \(j.to)", at: Date(), note: nil)
        Items.writeState(st, dir)
    }

    /// Sends a processed recording: what was said (the transcript, not the audio), where the cursor was and on what,
    /// and the screenshots it pointed at. Then it is done here, with a note where it went.
    static func send(_ dir: URL, to j: JoinRecord, as name: String = myName) async throws {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("events.json")),
              let events = try? JSONDecoder.iso.decode(SessionEvents.self, from: data),
              let words = try? Data(contentsOf: dir.appendingPathComponent("transcript.json")) else {
            throw Links.Failure.refused("nothing said in \(dir.lastPathComponent)")
        }
        var files = ["events.json": data.base64EncodedString(), "transcript.json": words.base64EncodedString()]
        var size = data.count + words.count
        for f in Set(events.points.compactMap(\.frame)).sorted() {
            guard let jpg = try? Data(contentsOf: dir.appendingPathComponent(f)), size + jpg.count < 14 << 20 else { continue }
            files[f] = jpg.base64EncodedString()
            size += jpg.count
        }
        guard let relay = URL(string: j.relay), let key = Links.unb64url(j.key), let raw = Data(base64Encoded: j.ownerKey) else {
            throw Links.Failure.refused("the link is broken")
        }
        let plain = try JSONEncoder().encode(Recording(name: name, files: files))
        let sealed = try Links.sealFeedback(plain, to: try P256.KeyAgreement.PublicKey(x963Representation: raw), linkKey: key, id: j.id)
        _ = try await Links.call(relay, "POST", "/api/links/\(j.id)/feedback", token: nil, body: sealed)
        if fm.fileExists(atPath: dir.appendingPathComponent("session.md").path) {
            var st = Items.readState(dir) ?? ItemState(source: "session")
            st.items["1"] = .init(status: "done", by: "you", at: Date(), note: "Sent to \(j.to)")
            Items.writeState(st, dir)
        }
    }

    /// Recordings still waiting to go (the relay was down): tried again.
    static func retry() async {
        guard let j = current() else { return }
        for dir in Items.sessionDirs() {
            guard let e = Items.readState(dir)?.items["1"], e.status == "triage", e.by?.hasPrefix("sending to") == true else { continue }
            try? await send(dir, to: j)
        }
    }
}
