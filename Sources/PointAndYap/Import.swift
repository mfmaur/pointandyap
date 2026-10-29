import Foundation

/// `PointAndYap --import <folder or .zip> [--author name]`: someone else's recording, sent as its session folder or a zip
/// of it, becomes a session here with their name on it, and so an item in the queue. Only the files a recording is made
/// of are copied (events.json, transcript.json, audio.caf, frames/NNN.jpg); the timeline and crops are built again here.
enum Import {
    enum Failure: Error, CustomStringConvertible {
        case refused(String)
        var description: String { if case .refused(let s) = self { return s }; return "" }
    }

    static let maxBytes = 500 << 20

    /// `triage`: from someone not at this Mac without the user asking for it, so no agent takes it before the user accepts.
    static func run(_ src: URL, author: String?, via: String = "import", triage: Bool = false) async throws -> URL {
        let fm = FileManager.default
        var from = src
        var unzipped: URL?
        defer { if let unzipped { try? fm.removeItem(at: unzipped) } }
        if src.pathExtension.lowercased() == "zip" {
            let tmp = fm.temporaryDirectory.appendingPathComponent("pointandyap-import-\(UUID().uuidString)")
            try unzip(src, to: tmp)
            unzipped = tmp
            from = tmp
        }
        guard let root = recording(in: from) else { throw Failure.refused("no events.json in \(src.path)") }

        let events = try decode(SessionEvents.self, root.appendingPathComponent("events.json"), iso: true)
        var files = ["events.json"]
        if fm.fileExists(atPath: root.appendingPathComponent("transcript.json").path) {
            _ = try decode([Word].self, root.appendingPathComponent("transcript.json"), iso: false)
            files.append("transcript.json")
        }
        if regular(root.appendingPathComponent("audio.caf")) { files.append("audio.caf") }
        let frames = ((try? fm.contentsOfDirectory(atPath: root.appendingPathComponent("frames").path)) ?? [])
            .filter { frameName("frames/\($0)") }.map { "frames/\($0)" }
            .filter { regular(root.appendingPathComponent($0)) }
        files += frames
        let size = files.reduce(0) { $0 + ((try? root.appendingPathComponent($1).resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        guard size <= maxBytes else { throw Failure.refused("\(size >> 20) MB is more than a recording should be (\(maxBytes >> 20) MB)") }

        // Frames are named by us, never by the sender: a name outside frames/NNN.jpg is dropped, not followed.
        var e = events
        let known = Set(frames)
        e.frames = e.frames.filter { known.contains($0.file) }
        for i in e.points.indices where !(e.points[i].frame.map(known.contains) ?? true) { e.points[i].frame = nil }
        e.author = Author(name: author ?? events.author?.name ?? "someone else", via: via)

        let dst = fresh()
        try fm.createDirectory(at: dst.appendingPathComponent("frames"), withIntermediateDirectories: true)
        for f in files where f != "events.json" { try fm.copyItem(at: root.appendingPathComponent(f), to: dst.appendingPathComponent(f)) }
        try JSONEncoder.pretty.encode(e).write(to: dst.appendingPathComponent("events.json"))
        if triage {
            var st = ItemState(source: "session")
            st.items["1"] = .init(status: "triage", by: e.author?.name, at: Date(), note: nil)
            Items.writeState(st, dst)
        }
        _ = await Process.run(dir: dst, log: { _ in })
        return dst
    }

    /// The folder holding events.json: the one given, or one level down (a zip of the session folder).
    static func recording(in dir: URL) -> URL? {
        if regular(dir.appendingPathComponent("events.json")) { return dir }
        let subs = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? [])
            .filter { $0.hasDirectoryPath && !$0.lastPathComponent.hasPrefix("__MACOSX") }
        return subs.first { regular($0.appendingPathComponent("events.json")) }
    }

    static func frameName(_ s: String) -> Bool { s.range(of: #"^frames/[0-9]{3,4}\.jpg$"#, options: .regularExpression) != nil }

    /// A plain file: not a link, not a folder.
    static func regular(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])).map { $0.isRegularFile == true && $0.isSymbolicLink != true } ?? false
    }

    /// Unzips with ditto after checking every entry name, so nothing lands outside `dir`.
    static func unzip(_ zip: URL, to dir: URL) throws {
        let names = try shell("/usr/bin/zipinfo", ["-1", zip.path]).split(separator: "\n").map(String.init)
        if let bad = names.first(where: { $0.hasPrefix("/") || $0.split(separator: "/").contains("..") }) {
            throw Failure.refused("the zip has an entry outside its folder: \(bad)")
        }
        _ = try shell("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path])
    }

    static func shell(_ path: String, _ args: [String]) throws -> String {
        let p = Foundation.Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Failure.refused("could not read \(args.last ?? path)") }
        return String(decoding: data, as: UTF8.self)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ url: URL, iso: Bool) throws -> T {
        guard regular(url), let data = try? Data(contentsOf: url),
              let v = try? (iso ? JSONDecoder.iso : JSONDecoder()).decode(type, from: data)
        else { throw Failure.refused("\(url.lastPathComponent) is not a Point and Yap recording") }
        return v
    }

    /// A new session id from now, never one that exists.
    static func fresh() -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        let base = f.string(from: Date())
        var dir = Paths.root.appendingPathComponent(base), n = 1
        while FileManager.default.fileExists(atPath: dir.path) { n += 1; dir = Paths.root.appendingPathComponent("\(base)-\(n)") }
        return dir
    }
}
