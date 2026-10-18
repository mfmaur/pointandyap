import AppKit

/// macOS asks to quit and reopen an app after Screen Recording (and for the key monitor, Accessibility) is granted,
/// but its "Quit & Reopen" often leaves the app closed. While a grant is being given, a small shell helper waits for
/// this process to end and opens the app again, for 10 minutes at most. A quit the user chooses in the app cancels it.
enum Relaunch {
    private static var armed = false
    static var marker: URL { Paths.support.appendingPathComponent("reopen") }

    static func armForGrant() {
        guard AgentInstall.installed else { return }   // only the copy in /Applications reopens itself
        try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: marker.path, contents: nil)
        guard !armed else { return }
        armed = true
        let script = """
        pid=$1; app=$2; m=$3; end=$(( $(date +%s) + 600 ))
        while kill -0 "$pid" 2>/dev/null; do [ "$(date +%s)" -gt "$end" ] && exit 0; sleep 0.5; done
        [ -f "$m" ] || exit 0
        rm -f "$m"; sleep 0.5; /usr/bin/open "$app"
        """
        let p = Foundation.Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "reopen", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath, marker.path]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    /// The user's own Quit: stay closed.
    static func cancel() { try? FileManager.default.removeItem(at: marker) }
}
