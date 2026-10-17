import Foundation

/// One Messages API call that turns session.md and its crops into instructions for a coding agent.
enum Claude {
    static let model = "claude-opus-5-5"
    static let maxImages = 12

    static var apiKey: String? {
        if let k = ProcessInfo.processInfo.environment["POINT_ANTHROPIC_KEY"], !k.isEmpty { return k }
        guard let s = try? String(contentsOf: Paths.keyFile, encoding: .utf8) else { return nil }
        let k = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return k.isEmpty ? nil : k
    }

    static let system = """
    You turn a narrated screen session into instructions for a coding agent. The person talked while pointing at things \
    on screen with the cursor. You get the aligned timeline (session.md: sentences with [n] markers where the cursor rested \
    or clicked, and the Accessibility element under each point) and crops of the screen at those points (red ring = cursor, \
    yellow box = element frame).

    Write the instructions in Markdown, in English, in this shape and nothing else:

    # <one-line summary of what the person wants>

    App: <app name and bundle id>, <screen or window>

    ## 1. <short title>
    - Where: <the exact element: role, visible text, window, identifier if any, and what surrounds it>
    - Now: <what the screen shows, read from the crop>
    - Wanted: <what the person asked for, in their intent, concrete>
    - Said: "<their words, verbatim, short>" (<mm:ss>)
    - Evidence: `<absolute crop path>`

    (one section per distinct request, in the order spoken; merge repeats)

    ## Open questions
    - <anything ambiguous the agent should ask about; omit the section if none>

    Rules: resolve "this", "here", "that" to the pointed element using the [n] markers. Only state what the words, the \
    elements or the crops support; never invent requirements. If a point is just cursor travel, ignore it. Keep visible \
    text exactly as on screen. No preamble.
    """

    /// The local Claude Code CLI, for writing the instructions on Marc's subscription when there is no API key or credit.
    static var cli: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .map(URL.init(fileURLWithPath:)).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func instructionsWithCLI(dir: URL) async throws -> String {
        guard let cli else { throw NSError(domain: "Point", code: 3, userInfo: [NSLocalizedDescriptionKey: "no claude CLI"]) }
        let prompt = "Read \(dir.appendingPathComponent("session.md").path) and every crop image it lists (use the Read tool "
            + "on each path), then reply with the instructions only."
        let p = Foundation.Process()
        p.executableURL = cli
        p.currentDirectoryURL = dir
        // A clean environment, so the CLI uses Marc's own login and not a parent session's.
        let env = ProcessInfo.processInfo.environment
        p.environment = ["HOME": env["HOME"] ?? NSHomeDirectory(), "USER": env["USER"] ?? NSUserName(),
                         "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"]
        p.arguments = ["-p", prompt, "--append-system-prompt", system, "--allowedTools", "Read",
                       "--add-dir", dir.path, "--output-format", "text"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = await Task.detached { out.fileHandleForReading.readDataToEndOfFile() }.value
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard p.terminationStatus == 0, !text.isEmpty else {
            throw NSError(domain: "Point", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "claude CLI failed"])
        }
        return text
    }

    static func instructions(sessionMarkdown: String, crops: [(index: Int, path: URL)]) async throws -> String {
        guard let key = apiKey else { throw NSError(domain: "Point", code: 1, userInfo: [NSLocalizedDescriptionKey: "no API key"]) }
        var content: [[String: Any]] = []
        for c in crops.prefix(maxImages) {
            guard let data = try? Data(contentsOf: c.path) else { continue }
            content.append(["type": "text", "text": "Crop for point [\(c.index + 1)]: \(c.path.path)"])
            content.append(["type": "image",
                            "source": ["type": "base64", "media_type": "image/jpeg", "data": data.base64EncodedString()]])
        }
        content.append(["type": "text", "text": sessionMarkdown])

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "system": system,
            "output_config": ["effort": "medium"],
            "fallbacks": "default",
            "messages": [["role": "user", "content": content]],
        ]
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "Point", code: status, userInfo: [NSLocalizedDescriptionKey: "unreadable answer (\(status))"])
        }
        guard status == 200 else {
            let msg = (json["error"] as? [String: Any])?["message"] as? String ?? "HTTP \(status)"
            throw NSError(domain: "Point", code: status, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        if json["stop_reason"] as? String == "refusal" {
            throw NSError(domain: "Point", code: 2, userInfo: [NSLocalizedDescriptionKey: "the model declined"])
        }
        let blocks = json["content"] as? [[String: Any]] ?? []
        let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        if let usage = json["usage"] as? [String: Any] {
            NSLog("point: claude usage in=\(usage["input_tokens"] ?? "?") out=\(usage["output_tokens"] ?? "?")")
        }
        return text
    }
}
