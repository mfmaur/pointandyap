import AVFoundation
import CoreMedia
import Foundation
import Speech

/// On-device transcription of a finished recording with word time ranges (SpeechAnalyzer, macOS 26).
enum Transcriber {
    enum Failure: Error, CustomStringConvertible {
        case noLocale(String)
        var description: String {
            switch self { case .noLocale(let id): return "no on-device speech model for \(id)" }
        }
    }

    /// The language: `defaults write com.marcmaurer.point locale de-DE`, else the system's.
    static var wantedLocale: Locale {
        if let id = UserDefaults.standard.string(forKey: "locale"), !id.isEmpty { return Locale(identifier: id) }
        return Locale.current
    }

    static func words(from audio: URL, locale wanted: Locale = wantedLocale) async throws -> [Word] {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) else {
            throw Failure.noLocale(wanted.identifier)
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: audio)

        let collect = Task { () throws -> [Word] in
            var out: [Word] = []
            for try await result in transcriber.results {
                for run in result.text.runs {
                    let text = String(result.text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty, let range = run.audioTimeRange else { continue }
                    out.append(Word(text: text, start: round3(range.start.seconds), end: round3(range.end.seconds)))
                }
            }
            return out
        }
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collect.value
    }
}
