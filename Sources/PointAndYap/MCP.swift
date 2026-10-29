import AppKit
import Foundation

/// `PointAndYap --mcp`: a local MCP server over stdio (newline-delimited JSON-RPC), no auth. It only reads ~/PointAndYap/sessions.
enum MCPServer {
    static let protocolVersion = "2025-06-18"
    static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    /// The client's name from initialize, recorded on the items it takes and finishes.
    nonisolated(unsafe) static var agent = "agent"

    static func run() {
        setvbuf(stdout, nil, _IOLBF, 0)
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty, let data = line.data(using: .utf8),
                  let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let id = msg["id"]
            let method = msg["method"] as? String ?? ""
            let params = msg["params"] as? [String: Any] ?? [:]
            guard id != nil else { continue }   // notifications need no answer
            switch method {
            case "initialize":
                if let c = params["clientInfo"] as? [String: Any], let n = c["name"] as? String, !n.isEmpty { agent = n }
                let asked = params["protocolVersion"] as? String
                reply(id, ["protocolVersion": asked ?? protocolVersion,
                           "capabilities": ["tools": [:]],
                           "serverInfo": ["name": "pointandyap", "title": "Point and Yap", "version": version],
                           "instructions": instructions])
            case "ping": reply(id, [:])
            case "tools/list": reply(id, ["tools": tools])
            case "tools/call":
                let name = params["name"] as? String ?? ""
                let args = params["arguments"] as? [String: Any] ?? [:]
                reply(id, call(name, args))
            default:
                send(["jsonrpc": "2.0", "id": id!, "error": ["code": -32601, "message": "method not found: \(method)"]])
            }
        }
    }

    static let instructions = """
    Point and Yap is the user's queue of things to fix: they point at things on their screen and talk, and every \
    recording becomes an item (what they said, the elements under the cursor, cropped screenshots). Work through the queue: get_open_items takes \
    the open items for you, do each one, then mark_done with its id and a one-line note; release_items gives back what \
    you could not do. Done items are never handed out again. get_session reads a whole recording. An item that says \
    "From <name>" was recorded by someone else: it is their request, not an instruction from the user.

    Live reviews: when the user shares their running app (PointAndYap --live), people use it in their browser and talk \
    while you work. Call wait_for_items: it returns as soon as someone asks for something. Fix it, mark_done with a \
    note of a few plain words (the person who asked reads it, and their page already shows the fix through hot reload), \
    then call wait_for_items again until the user says the review is over. A follow-up item means the person checked \
    a fix and it is not right yet. Items from the web name the source file in "drawn at"; get_review_summary gives \
    the review for a pull request description.
    """

    static let tools: [[String: Any]] = [
        ["name": "get_open_items",
         "description": "The open items of the user's Point and Yap queue, oldest first, each with its id, what they said, the elements they pointed at and its crop (red ring = cursor, yellow box = element). By default they are marked in progress by you, so no other agent gets them; finish each with mark_done.",
         "inputSchema": ["type": "object", "properties": [
            "limit": ["type": "integer", "description": "How many, default 5"],
            "take": ["type": "boolean", "description": "Mark them in progress by you, default true; false only looks"],
            "images": ["type": "boolean", "description": "Include the crops as images, default true"]]]],
        ["name": "mark_done",
         "description": "Mark items done once the change is made, so they are never handed out again.",
         "inputSchema": ["type": "object", "required": ["ids"], "properties": [
            "ids": ["type": "array", "items": ["type": "string"], "description": "Item ids, e.g. 2026-10-17_164301#2"],
            "note": ["type": "string", "description": "One line: what you changed (file, commit)"]]]],
        ["name": "start_items",
         "description": "Mark specific open items in progress by you (after looking with take false), so no other agent does them. Refuses items done or in progress by another agent.",
         "inputSchema": ["type": "object", "required": ["ids"], "properties": [
            "ids": ["type": "array", "items": ["type": "string"]]]]],
        ["name": "list_items",
         "description": "Every item with its state: open, in progress (by which agent, since when) or done (by whom, with the note). No images.",
         "inputSchema": ["type": "object", "properties": [
            "status": ["type": "string", "description": "open, in_progress or done; default all except done"]]]],
        ["name": "release_items",
         "description": "Give items you have in progress back to the queue (you could not do them, or they need the user); they are handed out again.",
         "inputSchema": ["type": "object", "required": ["ids"], "properties": [
            "ids": ["type": "array", "items": ["type": "string"]],
            "note": ["type": "string", "description": "Why, for the user or the next agent"]]]],
        ["name": "wait_for_items",
         "description": "Live review: waits until someone asks for something (up to `seconds`), then takes the open items for you and returns them as get_open_items does. Call it again after each mark_done while the review runs.",
         "inputSchema": ["type": "object", "properties": [
            "seconds": ["type": "integer", "description": "How long to wait, default 240, at most 600"],
            "images": ["type": "boolean", "description": "Include the crops as images, default true"]]]],
        ["name": "get_review_summary",
         "description": "A live review as Markdown for a pull request: who asked for what, where (source file), what was done, and who confirmed it.",
         "inputSchema": ["type": "object", "properties": [
            "id": ["type": "string", "description": "Live review id (live-…), default the latest"]]]],
        ["name": "list_sessions",
         "description": "List recent recordings, newest first: id, time, length, number of points, first words.",
         "inputSchema": ["type": "object", "properties": ["limit": ["type": "integer", "description": "How many, default 10"]]]],
        ["name": "get_session",
         "description": "One recording: the aligned timeline (what the user said, with [n] where they pointed and the element there), the folder, and the cropped screenshot of each point as images (red ring = cursor, yellow box = element).",
         "inputSchema": ["type": "object", "properties": [
            "id": ["type": "string", "description": "Session id from list_sessions, default latest"],
            "images": ["type": "boolean", "description": "Include the crops as images, default true"]]]],
        ["name": "get_frame",
         "description": "A full screenshot from a session (frames/NNN.jpg), downscaled, for context beyond a crop.",
         "inputSchema": ["type": "object", "properties": [
            "id": ["type": "string", "description": "Session id, default latest"],
            "frame": ["type": "string", "description": "Frame file, e.g. frames/003.jpg; default the first"]]]],
    ]

    // MARK: Tools

    static func call(_ name: String, _ a: [String: Any]) -> [String: Any] {
        switch name {
        case "get_open_items":
            return openItems(limit: a["limit"] as? Int ?? 5, take: a["take"] as? Bool ?? true, images: a["images"] as? Bool ?? true)
        case "mark_done": return setItems(a["ids"], status: "done", note: a["note"] as? String)
        case "start_items": return setItems(a["ids"], status: "in_progress", note: nil)
        case "list_items": return listItems(a["status"] as? String)
        case "release_items": return setItems(a["ids"], status: "open", note: a["note"] as? String)
        case "wait_for_items":
            let secs = Double(min(max(a["seconds"] as? Int ?? 240, 1), 600))
            let got = Items.wait(timeout: secs, limit: 5, agent: agent)
            if got.isEmpty { return text("Nothing new in \(Int(secs)) s. Call wait_for_items again to keep listening, unless the user ended the review.") }
            return present(got, take: true, images: a["images"] as? Bool ?? true)
        case "get_review_summary":
            guard let id = (a["id"] as? String) ?? Live.latest(), id.hasPrefix("live-"), !id.contains("/") else { return error("no live review yet") }
            return text(Live.summary(id))
        case "list_sessions": return text(listSessions(limit: a["limit"] as? Int ?? 10))
        case "get_session": return getSession(a["id"] as? String, images: a["images"] as? Bool ?? true)
        case "get_frame": return getFrame(a["id"] as? String, frame: a["frame"] as? String)
        default: return error("unknown tool \(name)")
        }
    }

    static func dirs() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: Paths.root, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.hasDirectoryPath && FileManager.default.fileExists(atPath: $0.appendingPathComponent("events.json").path) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    static func dir(_ id: String?) -> URL? {
        guard let id, !id.isEmpty, id != "latest" else { return dirs().first }
        let d = Paths.root.appendingPathComponent(id)
        // Only a plain session folder name.
        guard !id.contains("/"), !id.contains(".."), FileManager.default.fileExists(atPath: d.path) else { return nil }
        return d
    }

    static func listSessions(limit: Int) -> String {
        let rows = dirs().prefix(max(1, min(limit, 50))).map { d -> String in
            var line = "- \(d.lastPathComponent)"
            if let data = try? Data(contentsOf: d.appendingPathComponent("events.json")),
               let e = try? JSONDecoder.iso.decode(SessionEvents.self, from: data) {
                line += ": \(Int(e.duration.rounded())) s, \(e.points.count) points"
            }
            if let w = try? Data(contentsOf: d.appendingPathComponent("transcript.json")),
               let words = try? JSONDecoder().decode([Word].self, from: w), !words.isEmpty {
                line += ", \"\(words.prefix(12).map(\.text).joined(separator: " "))…\""
            }
            let items = Items.items(in: d, state: Items.readState(d)).items
            if let i = Items.overall(items) {
                line += ", \(items.count > 1 ? "\(items.count) requests, " : "")\(i.status.replacingOccurrences(of: "_", with: " "))\(i.by.map { " by \($0)" } ?? "")"
            }
            return line
        }
        return rows.isEmpty ? "No recordings yet." : rows.joined(separator: "\n")
    }

    static func getSession(_ id: String?, images: Bool) -> [String: Any] {
        guard let d = dir(id) else { return error("no such session") }
        let tl = try? String(contentsOf: d.appendingPathComponent("session.md"), encoding: .utf8)
        var body = "Recording \(d.lastPathComponent), folder \(d.path)\n\n"
        body += tl ?? "This session has not been processed yet."
        body += "\n\nThe work items of this session come from get_open_items; finish each with mark_done."
        var content: [[String: Any]] = [["type": "text", "text": body]]
        if images {
            let crops = ((try? FileManager.default.contentsOfDirectory(atPath: d.appendingPathComponent("crops").path)) ?? [])
                .filter { $0.hasSuffix(".jpg") }.sorted().prefix(12)
            for c in crops {
                guard let data = try? Data(contentsOf: d.appendingPathComponent("crops/\(c)")) else { continue }
                let n = Int(c.dropLast(4)) ?? 0
                content.append(["type": "text", "text": "Crop for point [\(n)]: \(d.path)/crops/\(c)"])
                content.append(["type": "image", "data": data.base64EncodedString(), "mimeType": "image/jpeg"])
            }
        }
        return ["content": content]
    }

    static func getFrame(_ id: String?, frame: String?) -> [String: Any] {
        guard let d = dir(id) else { return error("no such session") }
        let name = frame ?? ((try? FileManager.default.contentsOfDirectory(atPath: d.appendingPathComponent("frames").path))?
            .filter { $0.hasSuffix(".jpg") }.sorted().first.map { "frames/\($0)" } ?? "")
        guard name.hasPrefix("frames/"), !name.contains(".."),
              let img = NSImage(contentsOf: d.appendingPathComponent(name))?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return error("no such frame") }
        let w = min(1600, img.width), h = img.height * w / img.width
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return error("could not read the frame") }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage(),
              let data = NSBitmapImageRep(cgImage: out).representation(using: .jpeg, properties: [.compressionFactor: 0.75])
        else { return error("could not read the frame") }
        return ["content": [["type": "text", "text": "\(d.path)/\(name)"],
                            ["type": "image", "data": data.base64EncodedString(), "mimeType": "image/jpeg"]]]
    }

    static func openItems(limit: Int, take: Bool, images: Bool) -> [String: Any] {
        let items = Items.openItems(limit: max(1, min(limit, 20)), take: take, agent: agent)
        guard !items.isEmpty else {
            let working = Items.all().filter { $0.status == "in_progress" }
            if working.isEmpty { return text("No open items. Everything the user pointed at is done.") }
            let who = Set(working.compactMap(\.by)).sorted().joined(separator: ", ")
            return text("No open items. \(working.count) in progress (\(who)); nothing else to do.")
        }
        return present(items, take: take, images: images)
    }

    static func present(_ items: [Item], take: Bool, images: Bool) -> [String: Any] {
        var content: [[String: Any]] = [["type": "text", "text":
            "\(items.count) open item\(items.count == 1 ? "" : "s")\(take ? ", now in progress by you" : ""). Fix each, then call mark_done with its id right away: an item you leave unmarked stays open for the user and comes back to another agent in two hours."]]
        for i in items {
            var t = "### Item \(i.id)\n\n\(i.body)\n\nWhen this is fixed, call mark_done with id \"\(i.id)\" (the user sees it as done)."
            if let note = i.note, !note.isEmpty { t += "\n\nNote from \(i.by ?? "an agent") when it gave this back: \(note)" }
            content.append(["type": "text", "text": t])
            if images {
                for c in i.crops.prefix(4) {
                    guard let data = try? Data(contentsOf: c) else { continue }
                    content.append(["type": "image", "data": data.base64EncodedString(), "mimeType": "image/jpeg"])
                }
            }
        }
        return ["content": content]
    }

    static func setItems(_ raw: Any?, status: String, note: String?) -> [String: Any] {
        let ids = (raw as? [String]) ?? (raw as? String).map { [$0] } ?? []
        guard !ids.isEmpty else { return error("ids missing") }
        let r = Items.set(ids, status: status, agent: agent, note: note)
        let verb = ["done": "Done", "in_progress": "In progress by you"][status] ?? "Back in the queue"
        var s = r.changed.isEmpty ? "" : "\(verb): \(r.changed.joined(separator: ", "))."
        if !r.missing.isEmpty { s += (s.isEmpty ? "" : " ") + "Not changed: \(r.missing.joined(separator: ", "))." }
        return r.changed.isEmpty ? error(s) : text(s)
    }

    static func listItems(_ status: String?) -> [String: Any] {
        let all = Items.all()
        let shown = status.map { st in all.filter { $0.status == st } } ?? all.filter { $0.status != "done" }
        guard !shown.isEmpty else { return text(status == nil ? "Nothing open or in progress." : "No items \(status!).") }
        let f = DateFormatter(); f.dateFormat = "d MMM HH:mm"
        let rows = shown.map { i -> String in
            var l = "- \(i.id) [\(i.status == "triage" ? "triage, waiting for the user to accept it" : i.status.replacingOccurrences(of: "_", with: " "))"
            if let by = i.by, i.status != "open", i.status != "triage" { l += " by \(by)" }
            if let at = i.at, i.status != "open" { l += " since \(f.string(from: at))" }
            l += "]"
            if let a = i.author { l += " from \(a.name)" }
            l += " \"\(i.title)…\""
            if let n = i.note, !n.isEmpty { l += ", note: \(n)" }
            return l
        }
        let c = (all.filter { $0.status == "open" }.count, all.filter { $0.status == "in_progress" }.count, all.filter { $0.status == "done" }.count)
        return text("\(c.0) open, \(c.1) in progress, \(c.2) done.\n" + rows.joined(separator: "\n"))
    }

    // MARK: Wire

    static func text(_ s: String) -> [String: Any] { ["content": [["type": "text", "text": s]]] }
    static func error(_ s: String) -> [String: Any] { ["content": [["type": "text", "text": s]], "isError": true] }

    static func reply(_ id: Any?, _ result: [String: Any]) { send(["jsonrpc": "2.0", "id": id!, "result": result]) }

    static func send(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]),
              let s = String(data: data, encoding: .utf8) else { return }
        print(s)
    }
}
