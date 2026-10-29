import Foundation

/// `PointAndYap --items` and `PointAndYap --done <id>... [--note "..."]`: the queue for an agent that has a shell but not the MCP.
enum QueueCLI {
    static func run(_ args: [String]) {
        if args.contains("--items") {
            let items = Items.all().filter { $0.status != "done" }
            if items.isEmpty { print("Nothing open in Point and Yap."); return }
            for i in items {
                print("## \(i.id) [\(i.status.replacingOccurrences(of: "_", with: " "))\(i.status == "triage" ? "" : i.by.map { " by \($0)" } ?? "")]\(i.author.map { " from \($0.name)" } ?? "")\n\(i.body)\n")
            }
            print("When an item is fixed: \(binary) --done <id> --note \"what changed\"")
            return
        }
        var ids: [String] = [], note: String?, i = (args.firstIndex(of: "--done") ?? 0) + 1
        while i < args.count {
            if args[i] == "--note", i + 1 < args.count { note = args[i + 1]; i += 2; continue }
            if !args[i].hasPrefix("--") { ids.append(args[i]) }
            i += 1
        }
        guard !ids.isEmpty else { print("Usage: PointAndYap --done <id>... [--note \"what changed\"]"); exit(2) }
        let r = Items.set(ids, status: "done", agent: ProcessInfo.processInfo.environment["POINTANDYAP_AGENT"] ?? "shell", note: note)
        if !r.changed.isEmpty { print("Done: \(r.changed.joined(separator: ", "))") }
        if !r.missing.isEmpty { print("Not changed: \(r.missing.joined(separator: ", "))"); exit(1) }
    }

    /// `--wait [seconds]`: blocks until something is open (default 10 minutes), takes it and prints it.
    static func wait(_ args: [String]) {
        let secs = args.firstIndex(of: "--wait").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil } ?? 600
        let agent = ProcessInfo.processInfo.environment["POINTANDYAP_AGENT"] ?? "shell"
        let items = Items.wait(timeout: secs, limit: 5, agent: agent)
        if items.isEmpty { print("Nothing new in \(Int(secs)) s. Run --wait again to keep listening."); return }
        for i in items { print("## \(i.id) [in progress by \(agent)]\(i.author.map { " from \($0.name)" } ?? "")\n\(i.body)\n") }
        print("When an item is fixed: \(binary) --done <id> --note \"what changed, in a few plain words\"; then --wait again.")
    }

    static let binary = AgentInstall.binary
}
