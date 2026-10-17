import Foundation

/// Registers Point's MCP and skill with the coding agents on this Mac, once per launch from /Applications. Adds, never
/// overwrites: an entry named "point" that is not ours is left alone. Each config is backed up before its first change.
enum AgentInstall {
    static let binary = "/Applications/Point.app/Contents/MacOS/Point"
    static let skill = "/Applications/Point.app/Contents/Resources/skill/point"
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    static func run(log: (String) -> Void = { NSLog("point: \($0)") }) {
        guard Bundle.main.bundlePath == "/Applications/Point.app" else { return }
        claudeCode(log); codex(log); cursor(log); skills(log)
    }

    private static func backup(_ file: URL) {
        let dir = Paths.support.appendingPathComponent("backups")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        try? FileManager.default.copyItem(at: file, to: dir.appendingPathComponent("\(file.lastPathComponent).\(f.string(from: Date()))"))
    }

    /// Claude Code: user scope through its own CLI (it owns ~/.claude.json).
    private static func claudeCode(_ log: (String) -> Void) {
        let cfg = home.appendingPathComponent(".claude.json")
        if let data = try? Data(contentsOf: cfg), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let servers = json["mcpServers"] as? [String: Any], servers["point"] != nil { return }
        guard let cli = Claude.cli else { return }
        if FileManager.default.fileExists(atPath: cfg.path) { backup(cfg) }
        let p = Foundation.Process()
        p.executableURL = cli
        p.arguments = ["mcp", "add", "--scope", "user", "point", "--", binary, "--mcp"]
        p.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); log("claude code mcp: exit \(p.terminationStatus)") } catch { log("claude code mcp: \(error)") }
    }

    /// Codex: an [mcp_servers.point] table appended to ~/.codex/config.toml.
    private static func codex(_ log: (String) -> Void) {
        let cfg = home.appendingPathComponent(".codex/config.toml")
        guard let text = try? String(contentsOf: cfg, encoding: .utf8) else { return }
        guard !text.contains("[mcp_servers.point]") else { return }
        backup(cfg)
        let block = (text.hasSuffix("\n") ? "" : "\n") + "\n[mcp_servers.point]\ncommand = \"\(binary)\"\nargs = [\"--mcp\"]\n"
        if let h = try? FileHandle(forWritingTo: cfg) { h.seekToEndOfFile(); h.write(Data(block.utf8)); try? h.close(); log("codex mcp added") }
    }

    /// Cursor: mcpServers.point in ~/.cursor/mcp.json.
    private static func cursor(_ log: (String) -> Void) {
        let cfg = home.appendingPathComponent(".cursor/mcp.json")
        guard FileManager.default.fileExists(atPath: home.appendingPathComponent(".cursor").path) else { return }
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: cfg) {
            guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }  // unreadable: leave it
            json = j
        }
        var servers = json["mcpServers"] as? [String: Any] ?? [:]
        guard servers["point"] == nil else { return }
        if FileManager.default.fileExists(atPath: cfg.path) { backup(cfg) }
        servers["point"] = ["command": binary, "args": ["--mcp"]]
        json["mcpServers"] = servers
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            try? data.write(to: cfg, options: .atomic); log("cursor mcp added")
        }
    }

    /// The skill as a link into the app bundle (as the Doppelganger skill is), in Claude Code's and the shared folder.
    private static func skills(_ log: (String) -> Void) {
        let fm = FileManager.default
        for folder in [".claude/skills", ".agents/skills"] {
            let parent = home.appendingPathComponent(folder)
            guard fm.fileExists(atPath: parent.path) else { continue }
            let link = parent.appendingPathComponent("point")
            if let dest = try? fm.destinationOfSymbolicLink(atPath: link.path) {
                if dest == skill { continue }
                if dest.hasSuffix("/Contents/Resources/skill/point") { try? fm.removeItem(at: link) } else { continue }
            } else if fm.fileExists(atPath: link.path) { continue }   // someone else's "point"
            do { try fm.createSymbolicLink(atPath: link.path, withDestinationPath: skill); log("skill linked in \(folder)") }
            catch { log("skill \(folder): \(error)") }
        }
    }
}
