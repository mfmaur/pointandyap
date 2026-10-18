import AudioToolbox
import AVFoundation
import CoreAudio

/// Records a microphone to a CAF file: the default input, unless that is Bluetooth (AirPods): then the Mac's built-in
/// microphone. Opening a Bluetooth input switches the headset into its call mode for the whole recording (everything
/// it plays sounds worse) and back when it stops, and that switch cut off the done sound.
///
/// The microphone is opened through an input-only audio unit bound to that one device before it is initialized, and
/// disposed when the recording stops. AVAudioEngine's input node (up to 0.1.3) joined the default input and output in a
/// default-device aggregate as soon as it was read, before the built-in microphone was set on it; macOS kept that
/// aggregate for the life of the app and rebuilt it on the new defaults whenever a device came or went, so a Bluetooth
/// headset that connected later was put into call mode with nothing recording, until the app quit.
final class AudioRecorder {
    enum Failure: LocalizedError {
        case noMicrophone
        case audioUnit(String, OSStatus)
        var errorDescription: String? {
            switch self {
            case .noMicrophone: return "No microphone"
            case .audioUnit(let step, let status): return "The microphone did not open (\(step), \(status))"
            }
        }
    }

    private var unit: AudioUnit?
    private var buffer: AVAudioPCMBuffer?
    private var file: AVAudioFile?

    static func askForAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func start(to url: URL) throws {
        guard let device = Self.recordingDevice() else { throw Failure.noMicrophone }
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        var made: AudioUnit?
        guard let component = AudioComponentFindNext(nil, &desc), AudioComponentInstanceNew(component, &made) == noErr,
              let unit = made else { throw Failure.audioUnit("new", noErr) }
        self.unit = unit
        do {
            try open(unit, device: device, to: url)
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if let unit {
            // Stop returns once the input callback has run for the last time.
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        unit = nil
        buffer = nil
        file = nil
    }

    // Input on element 1, output off on element 0, then the device: all before initialize, which opens the hardware.
    private func open(_ unit: AudioUnit, device: AudioDeviceID, to url: URL) throws {
        func check(_ step: String, _ status: OSStatus) throws {
            if status != noErr { throw Failure.audioUnit(step, status) }
        }
        var on: UInt32 = 1, off: UInt32 = 0, id = device
        try check("input", AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, 4))
        try check("output", AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, 4))
        try check("device", AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                                 &id, UInt32(MemoryLayout<AudioDeviceID>.size)))

        // The unit does not convert the rate on input: the file keeps the device's rate and channels, as float.
        var hw = AudioStreamBasicDescription(), size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check("device format", AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hw, &size))
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hw.mSampleRate > 0 ? hw.mSampleRate : 48_000,
                                         channels: max(hw.mChannelsPerFrame, 1), interleaved: false)
        else { throw Failure.audioUnit("format", noErr) }
        var client = format.streamDescription.pointee
        try check("format", AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client, size))

        var callback = AURenderCallbackStruct(inputProc: micInput, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check("callback", AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                                                   &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))
        try check("initialize", AudioUnitInitialize(unit))

        var maxFrames = UInt32(4096), frameSize = UInt32(MemoryLayout<UInt32>.size)
        AudioUnitGetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, &frameSize)
        buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(maxFrames, 4096))
        file = try AVAudioFile(forWriting: url, settings: format.settings)
        try check("start", AudioOutputUnitStart(unit))
    }

    // On the audio thread, while the unit runs.
    fileprivate func pull(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ time: UnsafePointer<AudioTimeStamp>,
                          _ frames: UInt32) -> OSStatus {
        guard let unit, let buffer, frames <= buffer.frameCapacity else { return noErr }
        buffer.frameLength = frames
        let status = AudioUnitRender(unit, flags, time, 1, frames, buffer.mutableAudioBufferList)
        if status == noErr { try? file?.write(from: buffer) }
        return status
    }

    // MARK: Devices

    /// The device a recording opens: the built-in microphone when the default input is Bluetooth, else the default input.
    static func recordingDevice() -> AudioDeviceID? {
        guard let def = defaultInput() else { return nil }
        if let builtIn = builtInInsteadOfBluetooth(def) {
            NSLog("pointandyap: default input is Bluetooth; recording from the built-in microphone")
            return builtIn
        }
        return def
    }

    /// The built-in microphone when `def` is a Bluetooth device, else nil (record from the default).
    static func builtInInsteadOfBluetooth(_ def: AudioDeviceID) -> AudioDeviceID? {
        guard transport(def).map(isBluetooth) == true else { return nil }
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

private func micInput(_ refCon: UnsafeMutableRawPointer, _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                      _ time: UnsafePointer<AudioTimeStamp>, _ bus: UInt32, _ frames: UInt32,
                      _ data: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    Unmanaged<AudioRecorder>.fromOpaque(refCon).takeUnretainedValue().pull(flags, time, frames)
}
