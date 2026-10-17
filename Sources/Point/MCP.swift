import AppKit
import Foundation

/// `Point --mcp`: a local MCP server over stdio (newline-delimited JSON-RPC), no auth. It only reads ~/Point/sessions.
enum MCPServer {
    static let protocolVersion = "2025-06-18"

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
                let asked = params["protocolVersion"] as? String
                reply(id, ["protocolVersion": asked ?? protocolVersion,
                           "capabilities": ["tools": [:]],
                           "serverInfo": ["name": "point", "version": "0.2.0"],
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
    Point records Marc talking about his screen while he points at things with the cursor. Each session has numbered \
    instructions (instructions.md, or the aligned timeline session.md) with the element under each point and a cropped \
    screenshot per point. Use get_session (default: the latest) when Marc refers to what he just recorded, showed or pointed at.
    """

    static let tools: [[String: Any]] = [
        ["name": "list_sessions",
         "description": "List recent Point recordings, newest first: id, time, length, number of points, first words.",
         "inputSchema": ["type": "object", "properties": ["limit": ["type": "integer", "description": "How many, default 10"]]]],
        ["name": "get_session",
         "description": "One Point recording: the instructions for a coding agent (or the aligned timeline), the folder, and the cropped screenshot of each point as images (red ring = cursor, yellow box = element).",
         "inputSchema": ["type": "object", "properties": [
            "id": ["type": "string", "description": "Session id from list_sessions, default latest"],
            "images": ["type": "boolean", "description": "Include the crops as images, default true"],
            "timeline": ["type": "boolean", "description": "Also include the aligned timeline when instructions exist, default false"]]]],
        ["name": "get_frame",
         "description": "A full screenshot from a session (frames/NNN.jpg), downscaled, for context beyond a crop.",
         "inputSchema": ["type": "object", "properties": [
            "id": ["type": "string", "description": "Session id, default latest"],
            "frame": ["type": "string", "description": "Frame file, e.g. frames/003.jpg; default the first"]]]],
    ]

    // MARK: Tools

    static func call(_ name: String, _ a: [String: Any]) -> [String: Any] {
        switch name {
        case "list_sessions": return text(listSessions(limit: a["limit"] as? Int ?? 10))
        case "get_session": return getSession(a["id"] as? String, images: a["images"] as? Bool ?? true, timeline: a["timeline"] as? Bool ?? false)
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
            line += FileManager.default.fileExists(atPath: d.appendingPathComponent("instructions.md").path) ? ", instructions" : ", timeline only"
            return line
        }
        return rows.isEmpty ? "No Point sessions yet." : rows.joined(separator: "\n")
    }

    static func getSession(_ id: String?, images: Bool, timeline: Bool) -> [String: Any] {
        guard let d = dir(id) else { return error("no such session") }
        let ins = try? String(contentsOf: d.appendingPathComponent("instructions.md"), encoding: .utf8)
        let tl = try? String(contentsOf: d.appendingPathComponent("session.md"), encoding: .utf8)
        var body = "Point session \(d.lastPathComponent), folder \(d.path)\n\n"
        if let ins { body += ins; if timeline, let tl { body += "\n\n---\n\n" + tl } }
        else if let tl { body += tl } else { body += "This session has not been processed yet." }
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
