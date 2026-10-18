import AppKit
import AVFoundation
import SwiftUI

struct SessionRow: Identifiable, Equatable {
    var id: String { dir.path }
    var dir: URL
    var date: Date
    var duration: Int
    var points: Int
    var title: String
    var status = ""     // open, in_progress, done; empty when nothing was said
    var by: String?
    var note: String?
}

@MainActor
final class AppState: ObservableObject {
    enum Phase: Equatable { case idle, recording(Date), processing }

    @Published var phase: Phase = .idle
    @Published var sessions: [SessionRow] = []
    @Published var toast: String?
    @Published var mic = false
    @Published var screen = false
    @Published var ax = false
    @Published var showSettings = false
    /// The how-it-works card: until Got it once, and whenever How it works is pressed.
    @Published var showWelcome = !UserDefaults.standard.bool(forKey: "welcomeSeen")

    func dismissWelcome() {
        UserDefaults.standard.set(true, forKey: "welcomeSeen")
        showWelcome = false
    }
    /// A new version downloaded and ready to install (Updater).
    @Published var updateReady: String?
    /// The coding agents found on this Mac, while the first-run question is open.
    @Published var askAgents: [String] = []

    private var recorder: Recorder?
    var onRecordingChanged: ((Bool) -> Void)?
    /// The pill's frame in global top-left points: clicks there are not points.
    var ownUI: (() -> CGRect?)?

    var allowed: Bool { mic && screen && ax }

    func refreshAccess() {
        mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        screen = CGPreflightScreenCaptureAccess()
        ax = AXProbe.trusted
    }

    func askMic() { Task { _ = await AudioRecorder.askForAccess(); refreshAccess() } }
    func askScreen() {
        Relaunch.armForGrant()
        if !CGRequestScreenCaptureAccess() { openSettings("Privacy_ScreenCapture") }
        refreshAccess()
    }
    func askAX() { Relaunch.armForGrant(); AXProbe.askForTrust(); openSettings("Privacy_Accessibility") }

    private func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }

    func start() {
        guard phase == .idle else { return }
        let r = Recorder()
        r.ignore = { [weak self] in self?.ownUI?() }
        do { try r.start() } catch {
            say("Couldn't start: \(error.localizedDescription)")
            return
        }
        recorder = r
        phase = .recording(Date())
        Sounds.play("start")
        onRecordingChanged?(true)
    }

    /// Esc while recording: stop and keep nothing.
    func cancel() {
        guard case .recording = phase, let r = recorder else { return }
        recorder = nil
        r.cancel()
        phase = .idle
        onRecordingChanged?(false)
        if Prefs.sounds { NSSound(named: "Pop")?.play() }
        loadSessions()
    }

    /// Double Control: start when idle, stop while recording.
    func toggle() {
        switch phase {
        case .idle: if allowed { start() } else { NSSound(named: "Basso")?.play() }
        case .recording: stop()
        case .processing: break
        }
    }

    func stop() {
        guard case .recording = phase, let r = recorder else { return }
        recorder = nil
        phase = .processing
        onRecordingChanged?(false)
        Task {
            let dir = await r.stop()
            loadSessions()
            // The short pointer goes on the clipboard as soon as the timeline exists; the MCP and the folder fill in after.
            _ = await Process.run(dir: dir, onTimeline: { [weak self] in
                self?.copyPointer(dir)
                Sounds.play("done")
                self?.say("Copied. Paste it into your agent")
            })
            phase = .idle
            loadSessions()
        }
    }

    /// Two lines an agent can act on: what is new, and how to get it.
    static func pointer(_ dir: URL) -> String {
        let open = Items.all().filter { $0.status == "open" }.count
        let title = Items.items(in: dir, state: nil).items.first?.title ?? "a recording"
        return "New in Point and Yap: \"\(title)…\"\(open > 1 ? " (\(open) recordings to fix)" : "")\n"
            + "Fix them all: the pointandyap MCP get_open_items, then mark_done each when it is fixed. "
            + "Without the MCP: \(QueueCLI.binary) --items, and --done <id> --note \"what changed\"."
    }

    private func copyPointer(_ dir: URL) { copy(Self.pointer(dir)) }

    func copy(_ row: SessionRow) {
        copyPointer(row.dir)
        say("Copied")
    }

    /// The user marks a recording done themself, or opens it again.
    func toggleDone(_ row: SessionRow) {
        let ids = Items.items(in: row.dir, state: Items.readState(row.dir)).items.map(\.id)
        guard !ids.isEmpty else { return }
        _ = Items.set(ids, status: row.status == "done" ? "open" : "done", agent: "you", note: nil)
        loadSessions()
        say(row.status == "done" ? "Open again" : "Marked done")
    }

    /// The first-run answer: Connect registers the MCP and skill now and on later launches; Skip touches nothing.
    func answerAgents(_ yes: Bool) {
        UserDefaults.standard.set(yes, forKey: "connectAgents")
        UserDefaults.standard.set(true, forKey: "agentsAsked")
        askAgents = []
        if yes {
            DispatchQueue.global(qos: .userInitiated).async { AgentInstall.run() }
            say("Connected")
        }
    }

    func open(_ row: SessionRow) { NSWorkspace.shared.open(row.dir) }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func showToast(_ s: String) { say(s) }

    private func say(_ s: String) {
        toast = s
        Task { try? await Task.sleep(nanoseconds: 2_000_000_000); if toast == s { toast = nil } }
    }

    func loadSessions() {
        let fm = FileManager.default
        let dirs = ((try? fm.contentsOfDirectory(at: Paths.root, includingPropertiesForKeys: nil)) ?? [])
            .filter(\.hasDirectoryPath).sorted { $0.lastPathComponent > $1.lastPathComponent }.prefix(20)
        sessions = dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("events.json")),
                  let e = try? JSONDecoder.iso.decode(SessionEvents.self, from: data) else { return nil }
            var title = "No speech"
            if let w = try? Data(contentsOf: dir.appendingPathComponent("transcript.json")),
               let words = try? JSONDecoder().decode([Word].self, from: w), !words.isEmpty {
                title = words.prefix(9).map(\.text).joined(separator: " ")
            } else if phase == .processing {
                title = "Processing…"
            }
            let item = Items.items(in: dir, state: Items.readState(dir)).items.first
            return SessionRow(dir: dir, date: e.started, duration: Int(e.duration.rounded()), points: e.points.count,
                              title: title, status: item?.status ?? "", by: item?.by, note: item?.note)
        }
    }
}
