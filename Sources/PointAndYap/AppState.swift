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
    var noSpeech = false
    var author: String?   // someone else's recording
    var confirmed = false // they looked at the fix and said yes (live review)
    var requests = 1      // the things it asks for, each its own item
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
    /// Joined to someone's invite: recordings go to them (Join).
    @Published var joined: JoinRecord? = Join.current()
    /// An invite opened from a link, waiting for Join or Not now.
    @Published var invite: JoinRecord?

    func lookInvite(_ link: String) async {
        do { invite = try await Join.lookup(link) } catch { say("That invite does not open: \(error)") }
    }

    func answerInvite(_ yes: Bool) {
        if yes, let j = invite {
            do { try Join.join(j); joined = Join.current(); say("Recordings go to \(j.to) now") } catch { say("Couldn't join: \(error)") }
        }
        invite = nil
    }

    func leave() {
        Join.leave()
        joined = nil
        say("Recordings stay here again")
    }

    // MARK: Live review

    /// The port picker is open (Go live).
    @Published var pickingPort = false
    @Published var devServers: [DevServer] = []
    @Published var live: LiveSession?
    @Published var liveStarting = false
    /// Who is in the live link now (guests' names).
    @Published var livePeople: [String] = []
    /// Agents waiting for what they ask (wait_for_items) right now.
    @Published var liveAgents: [String] = []

    struct DevServer: Identifiable, Equatable { var port: Int; var name: String; var id: Int { port } }

    func pickPort() {
        pickingPort.toggle()
        guard pickingPort else { return }
        Task.detached {
            let found = DevServers.find().map { DevServer(port: $0.port, name: $0.name) }
            await MainActor.run { self.devServers = found }
        }
    }

    /// Shares localhost:<port> through a link, and copies it.
    func goLive(_ port: Int) {
        guard live == nil, !liveStarting else { return }
        let name = UserDefaults.standard.string(forKey: "shareName") ?? NSFullUserName().split(separator: " ").first.map(String.init) ?? "Me"
        let session = LiveSession(upstream: port, owner: name)
        session.onChange = { [weak self, weak session] in
            Task { @MainActor in
                guard let self, let session else { return }
                self.livePeople = await session.room.names
                self.liveAgents = await session.room.agents
                self.loadSessions()
            }
        }
        session.onEnd = { [weak self] in Task { @MainActor in self?.endLive() } }
        session.onRequest = { [weak self] name, titles in
            Task { @MainActor in
                Sounds.play("done")
                self?.say(titles.count == 1 ? "\(name): \"\(titles[0])…\"" : "\(name) asked for \(titles.count) things")
            }
        }
        liveStarting = true
        pickingPort = false
        Task {
            do {
                try await session.start()
                live = session
                copy(session.guestLink)
                Sounds.play("done")
                say("Live link copied")
            } catch {
                session.stop()
                say("Couldn't go live: \(error)")
            }
            liveStarting = false
        }
    }

    func endLive() {
        live?.stop()
        live = nil
        livePeople = []
        liveAgents = []
        say("Live link ended")
    }

    /// What to tell an agent so it fixes things as they are asked.
    static let liveAgentPrompt = "Work through Point and Yap live: call the pointandyap MCP wait_for_items, fix each item, mark_done it with a note, and wait again until I say stop."
    func copyAgentPrompt() { copy(Self.liveAgentPrompt); say("Copied. Paste it into your agent") }

    func copyLiveLink() { if let l = live?.guestLink { copy(l); say("Copied") } }
    func openLiveAsMe() { if let l = live?.ownerLink, let u = URL(string: l) { NSWorkspace.shared.open(u) } }

    /// The coding agents found on this Mac, while the first-run question is open.
    @Published var askAgents: [String] = []

    private var recorder: Recorder?
    private var marks: MarksOverlay?
    /// While recording: how many things are pointed at, and whether the next drag draws an area.
    @Published var pointed = 0
    @Published var areaOn = false
    var onRecordingChanged: ((Bool) -> Void)?
    /// The pill's frame in global top-left points: clicks there are not points.
    var ownUI: (() -> CGRect?)?

    var allowed: Bool { mic && screen && ax }

    func refreshAccess() {
        mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        screen = CGPreflightScreenCaptureAccess()
        ax = AXProbe.trusted
        // Once granted, a later reset (a reinstall) should show the system dialog again, which adds the app to the list.
        if screen { UserDefaults.standard.removeObject(forKey: "asked.screen") }
        if ax { UserDefaults.standard.removeObject(forKey: "asked.ax") }
    }

    func askMic() { Task { _ = await AudioRecorder.askForAccess(); refreshAccess() } }
    /// The first click shows the system's own dialog, which has its own Open System Settings button; later clicks
    /// open Settings directly. Doing both at once opened two of everything.
    func askScreen() {
        Relaunch.armForGrant()
        if firstAsk("screen") { CGRequestScreenCaptureAccess() } else { openSettings("Privacy_ScreenCapture") }
        refreshAccess()
    }
    func askAX() {
        Relaunch.armForGrant()
        if firstAsk("ax") { AXProbe.askForTrust() } else { openSettings("Privacy_Accessibility") }
    }

    private func firstAsk(_ what: String) -> Bool {
        let key = "asked.\(what)"
        defer { UserDefaults.standard.set(true, forKey: key) }
        return !UserDefaults.standard.bool(forKey: key)
    }

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
        let m = MarksOverlay(recorder: r)
        m.onChange = { [weak self, weak m] in guard let self, let m else { return }; self.pointed = m.count; self.areaOn = m.areaOn }
        marks = m
        phase = .recording(Date())
        Sounds.play("start")
        onRecordingChanged?(true)
    }

    /// Esc while recording: stop and keep nothing.
    func cancel() {
        guard case .recording = phase, let r = recorder else { return }
        recorder = nil
        endMarks()
        r.cancel()
        phase = .idle
        onRecordingChanged?(false)
        if Prefs.sounds { NSSound(named: "Pop")?.play() }
        loadSessions()
    }

    private func endMarks() { marks?.close(); marks = nil; pointed = 0; areaOn = false }
    /// The pill's Area: the next drag draws an area (⌥-drag does it without the button).
    func toggleArea() { marks?.areaOn.toggle() }
    /// The pill's undo: takes back the last thing pointed at (⌥-click a number for any other).
    func takeBackLast() { if pointed > 0 { recorder?.takeBack(pointed) } }

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
        endMarks()
        phase = .processing
        onRecordingChanged?(false)
        Task {
            let dir = await r.stop()
            // Joined: it is held from before it is listed, so this Mac's agents never take it, then sent.
            let to = Join.current()
            if let to { Join.hold(dir, for: to) }
            loadSessions()
            // The short pointer goes on the clipboard as soon as the timeline exists; the MCP and the folder fill in after.
            _ = await Process.run(dir: dir, onTimeline: { [weak self] in
                guard to == nil else { return }
                self?.copyPointer(dir)
                Sounds.play("done")
                self?.say("Copied. Paste it into your agent")
            })
            if let to {
                do {
                    try await Join.send(dir, to: to)
                    Sounds.play("done")
                    say("Sent to \(to.to)")
                } catch {
                    say("Not sent yet, trying again: \(error)")
                }
            }
            phase = .idle
            loadSessions()
        }
    }

    /// Two lines an agent can act on: what is new, and how to get it.
    static func pointer(_ dir: URL) -> String {
        let open = Items.all().filter { $0.status == "open" }.count
        let title = Items.items(in: dir, state: nil).items.first?.title ?? "a recording"
        return "New in Point and Yap: \"\(title)…\"\(open > 1 ? " (\(open) to fix)" : "")\n"
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

    /// From a review link: into the queue, for agents.
    func accept(_ row: SessionRow) {
        let ids = Items.items(in: row.dir, state: Items.readState(row.dir)).items.map(\.id)
        _ = Items.set(ids, status: "open", agent: "you", note: nil)
        loadSessions()
        // As after a recording of the user's own: the line for an agent goes on the clipboard.
        copyPointer(row.dir)
        Sounds.play("done")
        say("Copied. Paste it into your agent")
    }

    /// A review link for a recording's screenshots, on the clipboard.
    func share(_ row: SessionRow) {
        guard let relay = Links.relay() else { say("No relay yet: see Review links in DEVELOPMENT.md"); return }
        let name = UserDefaults.standard.string(forKey: "shareName") ?? NSFullUserName().split(separator: " ").first.map(String.init)
        Task {
            do {
                let r = try await Links.share(row.dir, relay: relay, from: name)
                copy(r.url)
                say("Review link copied")
            } catch {
                say("Couldn't share: \(error)")
            }
        }
    }

    private var pulling = false

    /// What guests sent to review links, into Recent in triage. Only when there are links.
    func pullLinks() {
        guard !pulling, !Links.all().isEmpty else { return }
        pulling = true
        Task.detached {
            let got = await Links.pull()
            await MainActor.run {
                self.pulling = false
                guard !got.isEmpty else { return }
                self.loadSessions()
                Sounds.play("done")
                self.say(got.count == 1 ? "New from a review link" : "\(got.count) new from review links")
            }
        }
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
            .filter(\.hasDirectoryPath).sorted { $0.lastPathComponent > $1.lastPathComponent }
        // The newest 20 with speech, and the ones without speech between them (hidden unless Settings shows them).
        var rows: [SessionRow] = []
        for row in dirs.lazy.compactMap({ dir -> SessionRow? in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("events.json")),
                  let e = try? JSONDecoder.iso.decode(SessionEvents.self, from: data) else { return nil }
            var title = "No speech"
            if let w = try? Data(contentsOf: dir.appendingPathComponent("transcript.json")),
               let words = try? JSONDecoder().decode([Word].self, from: w), !words.isEmpty {
                title = words.prefix(9).map(\.text).joined(separator: " ")
            } else if self.phase == .processing {
                title = "Processing…"
            }
            let items = Items.items(in: dir, state: Items.readState(dir)).items, item = Items.overall(items)
            return SessionRow(dir: dir, date: e.started, duration: Int(e.duration.rounded()), points: e.points.count,
                              title: title, status: item?.status ?? "", by: item?.by, note: item?.note,
                              noSpeech: title == "No speech", author: e.author?.name, confirmed: item?.confirmed != nil, requests: items.count)
        }) {
            rows.append(row)
            if rows.filter({ !$0.noSpeech }).count == 20 { break }
        }
        sessions = rows
    }
}
