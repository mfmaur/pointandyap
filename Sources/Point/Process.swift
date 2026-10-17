import Foundation

/// From a recorded folder to session.md and instructions.md. Returns the text to put on the clipboard.
enum Process {
    static func run(dir: URL, useClaude: Bool = true, log: (String) -> Void = { NSLog("point: \($0)") }) async -> String {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("events.json")),
              let events = try? JSONDecoder.iso.decode(SessionEvents.self, from: data) else {
            return "Point: no events.json in \(dir.path)"
        }
        var words: [Word] = []
        let audio = dir.appendingPathComponent("audio.caf")
        let wordsFile = dir.appendingPathComponent("transcript.json")
        if let cached = try? Data(contentsOf: wordsFile), let w = try? JSONDecoder().decode([Word].self, from: cached) {
            words = w
        } else if FileManager.default.fileExists(atPath: audio.path) {
            do {
                words = try await Transcriber.words(from: audio)
                try? JSONEncoder.pretty.encode(words).write(to: wordsFile)
            } catch {
                log("transcription failed: \(error)")
            }
        }
        log("\(words.count) words, \(events.points.count) points, \(events.frames.count) frames")

        let out = Builder.build(dir: dir, events: events, words: words)
        guard useClaude, !words.isEmpty else { return out.markdown }

        // The API when a key works, else the local Claude Code CLI, else session.md as it is.
        var text: String?
        if Claude.apiKey != nil {
            let crops = out.attached.compactMap { i in out.crops[i].map { (index: i, path: dir.appendingPathComponent($0)) } }
            do { text = try await Claude.instructions(sessionMarkdown: out.markdown, crops: crops) } catch {
                log("claude API failed: \(error.localizedDescription)")
            }
        }
        if text == nil, Claude.cli != nil {
            do { text = try await Claude.instructionsWithCLI(dir: dir) } catch { log("claude CLI failed: \(error.localizedDescription)") }
        }
        guard let text else { return out.markdown }
        let full = text + "\n\n---\nFrom a Point session; the aligned timeline is in `\(dir.appendingPathComponent("session.md").path)`.\n"
        try? full.write(to: dir.appendingPathComponent("instructions.md"), atomically: true, encoding: .utf8)
        return full
    }
}
