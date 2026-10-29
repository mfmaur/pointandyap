import Foundation

/// From a recorded folder to the timeline (session.md) and crops, all on this Mac. Returns session.md.
enum Process {
    static func run(dir: URL, log: (String) -> Void = { NSLog("pointandyap: \($0)") },
                    onTimeline: (@MainActor () -> Void)? = nil) async -> String {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("events.json")),
              let events = try? JSONDecoder.iso.decode(SessionEvents.self, from: data) else {
            return "Point and Yap: no events.json in \(dir.path)"
        }
        var words: [Word] = []
        // audio.wav: a guest's recording from a review link.
        let audio = ["audio.caf", "audio.wav"].map { dir.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) } ?? dir.appendingPathComponent("audio.caf")
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
        if let onTimeline { await onTimeline() }
        return out.markdown
    }
}
