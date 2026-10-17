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
    var hasInstructions: Bool
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
        if !CGRequestScreenCaptureAccess() { openSettings("Privacy_ScreenCapture") }
        refreshAccess()
    }
    func askAX() { AXProbe.askForTrust(); openSettings("Privacy_Accessibility") }

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
        NSSound(named: "Tink")?.play()
        onRecordingChanged?(true)
    }

    func stop() {
        guard case .recording = phase, let r = recorder else { return }
        recorder = nil
        phase = .processing
        onRecordingChanged?(false)
        Task {
            let dir = await r.stop()
            loadSessions()
            let text = await Process.run(dir: dir)
            copy(text)
            NSSound(named: "Glass")?.play()
            phase = .idle
            loadSessions()
            say(FileManager.default.fileExists(atPath: dir.appendingPathComponent("instructions.md").path)
                ? "Instructions copied" : "Timeline copied")
        }
    }

    func copy(_ row: SessionRow) {
        let file = ["instructions.md", "session.md"].map { row.dir.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        guard let file, let text = try? String(contentsOf: file, encoding: .utf8) else { say("Nothing to copy yet"); return }
        copy(text)
        say("Copied")
    }

    func open(_ row: SessionRow) { NSWorkspace.shared.open(row.dir) }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

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
                title = "Writing instructions…"
            }
            return SessionRow(dir: dir, date: e.started, duration: Int(e.duration.rounded()), points: e.points.count,
                              title: title, hasInstructions: fm.fileExists(atPath: dir.appendingPathComponent("instructions.md").path))
        }
    }
}
