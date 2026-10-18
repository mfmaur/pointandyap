import Foundation

/// `Point --items` and `Point --done <id>... [--note "..."]`: the queue for an agent that has a shell but not the MCP.
enum QueueCLI {
    static func run(_ args: [String]) {
        if args.contains("--items") {
            let items = Items.all().filter { $0.status != "done" }
            if items.isEmpty { print("Nothing open in Point and Yap."); return }
            for i in items {
                print("## \(i.id) [\(i.status.replacingOccurrences(of: "_", with: " "))\(i.by.map { " by \($0)" } ?? "")]\n\(i.body)\n")
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
        guard !ids.isEmpty else { print("Usage: Point --done <id>... [--note \"what changed\"]"); exit(2) }
        let r = Items.set(ids, status: "done", agent: ProcessInfo.processInfo.environment["POINT_AGENT"] ?? "shell", note: note)
        if !r.changed.isEmpty { print("Done: \(r.changed.joined(separator: ", "))") }
        if !r.missing.isEmpty { print("Not changed: \(r.missing.joined(separator: ", "))"); exit(1) }
    }

    static let binary = "/Applications/Point.app/Contents/MacOS/Point"
}
