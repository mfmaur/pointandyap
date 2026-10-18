import Foundation

/// Registers the MCP server and the skill with the coding agents on this Mac, from /Applications. Adds, never overwrites:
/// an entry with our name that is not ours is left alone. Entries of the earlier name ("point", pointing into
/// /Applications/Point.app) are replaced by the new ones. Each config is backed up before its first change.
enum AgentInstall {
    static let appPath = "/Applications/Point and Yap.app"
    static let binary = "\(appPath)/Contents/MacOS/PointAndYap"
    static let skill = "\(appPath)/Contents/Resources/skill/point-and-yap"
    static let server = "pointandyap"
    static let skillName = "point-and-yap"
    /// What builds before 0.1.1 wrote.
    static let oldServer = "point"
    static let oldApp = "/Applications/Point.app/"
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// The Claude Code CLI, only to register the MCP with it.
    static var claudeCLI: URL? {
        ["\(home.path)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .map(URL.init(fileURLWithPath:)).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static var installed: Bool { Bundle.main.bundlePath == appPath }

    /// Whether to show the first-run question. A Mac where the app is already registered with an agent, or where the
    /// switch was set before the question existed, counts as answered, with what it already has.
    static func needsAsking() -> Bool {
        let d = UserDefaults.standard
        if d.bool(forKey: "agentsAsked") { return false }
        let found = status()
        if d.object(forKey: "connectAgents") != nil || found.contains(where: \.on) {
            if d.object(forKey: "connectAgents") == nil { d.set(true, forKey: "connectAgents") }
            d.set(true, forKey: "agentsAsked")
            return false
        }
        return !found.isEmpty
    }

    static func run(force: Bool = false, log: (String) -> Void = { NSLog("pointandyap: \($0)") }) {
        guard installed, force || Prefs.connectAgents else { return }
        claudeCode(log); codex(log); cursor(log); skills(log)
    }

    /// Which agents on this Mac know the app (for Settings); an entry of the earlier name counts until it is replaced.
    static func status() -> [(name: String, on: Bool)] {
        var out: [(String, Bool)] = []
        let fm = FileManager.default
        let claude = home.appendingPathComponent(".claude.json")
        if fm.fileExists(atPath: claude.path) {
            let servers = (try? Data(contentsOf: claude)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["mcpServers"] as? [String: Any]
            out.append(("Claude Code", servers?[server] != nil || isOurOld(servers?[oldServer])))
        }
        if let t = try? String(contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8) {
            out.append(("Codex", t.contains("[mcp_servers.\(server)]") || t.contains("[mcp_servers.\(oldServer)]")))
        }
        if fm.fileExists(atPath: home.appendingPathComponent(".cursor").path) {
            let j = (try? Data(contentsOf: home.appendingPathComponent(".cursor/mcp.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let servers = j?["mcpServers"] as? [String: Any]
            out.append(("Cursor", servers?[server] != nil || isOurOld(servers?[oldServer])))
        }
        return out
    }

    /// An entry an earlier build wrote: its command runs the old app.
    static func isOurOld(_ entry: Any?) -> Bool {
        guard let e = entry as? [String: Any], let cmd = e["command"] as? String else { return false }
        return cmd.hasPrefix(oldApp)
    }

    private static func backup(_ file: URL) {
        let dir = Paths.support.appendingPathComponent("backups")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        try? FileManager.default.copyItem(at: file, to: dir.appendingPathComponent("\(file.lastPathComponent).\(f.string(from: Date()))"))
    }

    private static func claudeRun(_ args: [String], _ log: (String) -> Void) {
        guard let cli = claudeCLI else { return }
        let p = Foundation.Process()
        p.executableURL = cli
        p.arguments = args
        p.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); log("claude code \(args.prefix(2).joined(separator: " ")): exit \(p.terminationStatus)") }
        catch { log("claude code: \(error)") }
    }

    /// Claude Code: user scope through its own CLI (it owns ~/.claude.json).
    private static func claudeCode(_ log: (String) -> Void) {
        let cfg = home.appendingPathComponent(".claude.json")
        let servers = (try? Data(contentsOf: cfg)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["mcpServers"] as? [String: Any]
        let old = isOurOld(servers?[oldServer]), new = servers?[server] != nil
        guard old || !new, claudeCLI != nil else { return }
        if FileManager.default.fileExists(atPath: cfg.path) { backup(cfg) }
        if old { claudeRun(["mcp", "remove", "--scope", "user", oldServer], log) }
        if !new { claudeRun(["mcp", "add", "--scope", "user", server, "--", binary, "--mcp"], log) }
    }

    /// Codex: an [mcp_servers.pointandyap] table in ~/.codex/config.toml; the earlier [mcp_servers.point] table is removed
    /// when it runs the old app.
    private static func codex(_ log: (String) -> Void) {
        let cfg = home.appendingPathComponent(".codex/config.toml")
        guard var text = try? String(contentsOf: cfg, encoding: .utf8) else { return }
        let before = text
        text = removingTable("mcp_servers.\(oldServer)", from: text) { $0.contains(oldApp) }
        if !text.contains("[mcp_servers.\(server)]") {
            text += (text.hasSuffix("\n") ? "" : "\n") + "\n[mcp_servers.\(server)]\ncommand = \"\(binary)\"\nargs = [\"--mcp\"]\n"
        }
        guard text != before else { return }
        backup(cfg)
        do { try text.write(to: cfg, atomically: true, encoding: .utf8); log("codex mcp written") } catch { log("codex: \(error)") }
    }

    /// Removes a TOML table (its header to the next header) when `ours` says its body is ours.
    static func removingTable(_ name: String, from text: String, ours: (String) -> Bool) -> String {
        var lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(of: "[\(name)]") else { return text }
        var end = start + 1
        while end < lines.count, !lines[end].hasPrefix("[") { end += 1 }
        guard ours(lines[start..<end].joined(separator: "\n")) else { return text }
        while end < lines.count, lines[end].hasPrefix("[\(name).") {   // its sub-tables
            end += 1
            while end < lines.count, !lines[end].hasPrefix("[") { end += 1 }
        }
        var cut = start
        if cut > 0, lines[cut - 1].isEmpty { cut -= 1 }
        lines.removeSubrange(cut..<end)
        return lines.joined(separator: "\n")
    }

    /// Cursor: mcpServers.pointandyap in ~/.cursor/mcp.json.
    private static func cursor(_ log: (String) -> Void) {
        let cfg = home.appendingPathComponent(".cursor/mcp.json")
        guard FileManager.default.fileExists(atPath: home.appendingPathComponent(".cursor").path) else { return }
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: cfg) {
            guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }  // unreadable: leave it
            json = j
        }
        var servers = json["mcpServers"] as? [String: Any] ?? [:]
        let old = isOurOld(servers[oldServer])
        guard old || servers[server] == nil else { return }
        if FileManager.default.fileExists(atPath: cfg.path) { backup(cfg) }
        if old { servers[oldServer] = nil }
        if servers[server] == nil { servers[server] = ["command": binary, "args": ["--mcp"]] }
        json["mcpServers"] = servers
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            try? data.write(to: cfg, options: .atomic); log("cursor mcp written")
        }
    }

    /// The skill as a link into the app bundle, in Claude Code's and the shared skills folder; the earlier "point" link
    /// into the old app is removed.
    private static func skills(_ log: (String) -> Void) {
        let fm = FileManager.default
        for folder in [".claude/skills", ".agents/skills"] {
            let parent = home.appendingPathComponent(folder)
            guard fm.fileExists(atPath: parent.path) else { continue }
            let old = parent.appendingPathComponent(oldServer)
            if let dest = try? fm.destinationOfSymbolicLink(atPath: old.path), dest.hasPrefix(oldApp) { try? fm.removeItem(at: old) }
            let link = parent.appendingPathComponent(skillName)
            if let dest = try? fm.destinationOfSymbolicLink(atPath: link.path) {
                if dest == skill { continue }
                if dest.hasSuffix("/Contents/Resources/skill/\(skillName)") { try? fm.removeItem(at: link) } else { continue }
            } else if fm.fileExists(atPath: link.path) { continue }   // someone else's folder of that name
            do { try fm.createSymbolicLink(atPath: link.path, withDestinationPath: skill); log("skill linked in \(folder)") }
            catch { log("skill \(folder): \(error)") }
        }
    }
}
