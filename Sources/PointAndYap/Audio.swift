import AVFoundation

/// Records the default microphone to a CAF file.
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?

    static func askForAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func start(to url: URL) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        file = try AVAudioFile(forWriting: url, settings: format.settings)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            try? self?.file?.write(from: buffer)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil
    }
}
