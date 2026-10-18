import AVFoundation
import CoreAudio

/// Records a microphone to a CAF file: the default input, unless that is Bluetooth (AirPods): then the Mac's built-in
/// microphone. Opening a Bluetooth input switches the headset into its call mode for the whole recording (everything
/// it plays sounds worse) and back when it stops, and that switch cut off the done sound.
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?

    static func askForAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func start(to url: URL) throws {
        let input = engine.inputNode
        if let builtIn = Self.builtInInsteadOfBluetooth(), let unit = input.audioUnit {
            var id = builtIn
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            NSLog("pointandyap: default input is Bluetooth; recording from the built-in microphone (status \(status))")
        }
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

    // MARK: Devices

    /// The built-in microphone when the default input is a Bluetooth device, else nil (record from the default).
    static func builtInInsteadOfBluetooth() -> AudioDeviceID? {
        guard let def = defaultInput(), transport(def).map(isBluetooth) == true else { return nil }
        return devices().first { transport($0) == kAudioDeviceTransportTypeBuiltIn && hasInput($0) }
    }

    static func isBluetooth(_ t: UInt32) -> Bool {
        t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultInput() -> AudioDeviceID? {
        var a = address(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id) == noErr, id != 0
        else { return nil }
        return id
    }

    private static func devices() -> [AudioDeviceID] {
        var a = address(kAudioHardwarePropertyDevices)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func transport(_ id: AudioDeviceID) -> UInt32? {
        var a = address(kAudioDevicePropertyTransportType)
        var t = UInt32(0), size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &t) == noErr ? t : nil
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var a = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)
        var size = UInt32(0)
        return AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr && size > 0
    }
}
