@preconcurrency import AVFAudio
@preconcurrency import AudioToolbox
@preconcurrency import CoreAudio
import Foundation
import StenoAudioCore

/// A microphone capture built directly on a HAL audio unit.
///
/// Replaces `AVAudioEngine` in the recording path for one reason: reaching
/// `engine.inputNode` opens the system *default* input before the chosen device
/// can be set. While another app held a Bluetooth microphone, that single step
/// took 3012 ms of the 5000 ms start budget, and the recording lost its
/// microphone track no matter which device the user had picked. Setting the
/// device on the unit before initializing never touches the default device: the
/// same busy microphone came up in 34 ms.
final class HALInputUnit: @unchecked Sendable {
    /// The order in which the unit is brought up. Expressed as values so the
    /// order itself can be checked - it is the entire point of this type.
    enum SetupStep: Equatable, Sendable {
        case enableInputDisableOutput
        case setDevice(AudioDeviceID)
        case readHardwareFormat
        case setClientFormat
        case setInputCallback
        case initialize
        case start
    }

    static func setupSteps(deviceID: AudioDeviceID) -> [SetupStep] {
        [
            .enableInputDisableOutput,
            // Before everything that follows: this is what keeps the default
            // input device out of the picture.
            .setDevice(deviceID),
            .readHardwareFormat,
            .setClientFormat,
            .setInputCallback,
            .initialize,
            .start,
        ]
    }

    private var unit: AudioUnit?
    private var isInitialized = false
    private var isRunning = false
    private var renderBuffer: AVAudioPCMBuffer?
    private var hardwareFormat: AVAudioFormat?
    private var handler: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var boundDeviceID: AudioDeviceID?
    private var formatListener: AudioObjectPropertyListenerBlock?
    private let listenerQueue = DispatchQueue(
        label: "org.steno.microphone-unit-listener",
        qos: .userInitiated
    )

    deinit {
        stop()
    }

    /// Instantiates the unit, points it at `deviceID` and reports the format
    /// that device delivers. Nothing is initialized or started yet.
    func prepare(deviceID: AudioDeviceID) throws -> AVAudioFormat {
        stop()
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw AudioRecordingError.audioSourceUnavailable(
                "the system has no audio input component"
            )
        }
        var created: AudioUnit?
        let instantiation = AudioComponentInstanceNew(component, &created)
        guard instantiation == noErr, let created else {
            throw AudioRecordingError.audioSourceUnavailable(
                "the microphone audio unit could not be created (OSStatus \(instantiation))"
            )
        }
        unit = created

        var enable: UInt32 = 1
        try check(
            AudioUnitSetProperty(
                created,
                kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Input,
                Self.inputBus,
                &enable,
                UInt32(MemoryLayout<UInt32>.size)
            ),
            "the microphone input could not be enabled"
        )
        var disable: UInt32 = 0
        try check(
            AudioUnitSetProperty(
                created,
                kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Output,
                Self.outputBus,
                &disable,
                UInt32(MemoryLayout<UInt32>.size)
            ),
            "the unused audio output could not be disabled"
        )

        var mutableDeviceID = deviceID
        try check(
            AudioUnitSetProperty(
                created,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &mutableDeviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            ),
            "cannot select the recording microphone"
        )

        var streamDescription = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(
            AudioUnitGetProperty(
                created,
                kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Input,
                Self.inputBus,
                &streamDescription,
                &size
            ),
            "the microphone input format could not be read"
        )
        guard streamDescription.mSampleRate > 0,
              streamDescription.mChannelsPerFrame > 0,
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: streamDescription.mSampleRate,
                  channels: AVAudioChannelCount(streamDescription.mChannelsPerFrame),
                  interleaved: false
              ) else {
            throw AudioRecordingError.audioSourceUnavailable(
                "no usable microphone input format"
            )
        }
        hardwareFormat = format
        boundDeviceID = deviceID
        return format
    }

    /// Reports a format change on the bound device.
    ///
    /// `AVAudioEngine` announced this through `AVAudioEngineConfigurationChange`;
    /// a HAL unit has no such notification, so the device is observed directly.
    /// Without this the capture would keep writing through a route that has
    /// changed underneath it.
    func observeFormatChanges(_ onChange: @escaping @Sendable () -> Void) {
        guard let deviceID = boundDeviceID, formatListener == nil else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
        guard AudioObjectAddPropertyListenerBlock(
            deviceID,
            &address,
            listenerQueue,
            block
        ) == noErr else { return }
        formatListener = block
    }

    private func removeFormatListener() {
        guard let deviceID = boundDeviceID, let formatListener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            deviceID,
            &address,
            listenerQueue,
            formatListener
        )
        self.formatListener = nil
    }

    /// Sets the client format, hooks up the callback and starts the unit.
    func start(
        bufferHandler: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) throws {
        guard let unit, let hardwareFormat else {
            throw AudioRecordingError.audioSourceUnavailable(
                "the selected microphone was not prepared"
            )
        }
        handler = bufferHandler

        var client = hardwareFormat.streamDescription.pointee
        try check(
            AudioUnitSetProperty(
                unit,
                kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Output,
                Self.inputBus,
                &client,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            ),
            "the microphone client format was rejected"
        )

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: hardwareFormat,
            frameCapacity: Self.maximumFrames
        ) else {
            throw AudioRecordingError.audioSourceUnavailable(
                "the microphone buffer could not be allocated"
            )
        }
        renderBuffer = buffer

        var callback = AURenderCallbackStruct(
            inputProc: { context, flags, timeStamp, bus, frames, _ in
                let unitBox = Unmanaged<HALInputUnit>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                return unitBox.render(
                    flags: flags,
                    timeStamp: timeStamp,
                    bus: bus,
                    frames: frames
                )
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        try check(
            AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_SetInputCallback,
                kAudioUnitScope_Global,
                0,
                &callback,
                UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            ),
            "the microphone callback was rejected"
        )

        try check(AudioUnitInitialize(unit), "the microphone could not be initialized")
        isInitialized = true
        try check(AudioOutputUnitStart(unit), "the microphone could not be started")
        isRunning = true
    }

    func stop() {
        removeFormatListener()
        if let unit {
            if isRunning { AudioOutputUnitStop(unit) }
            if isInitialized { AudioUnitUninitialize(unit) }
            AudioComponentInstanceDispose(unit)
        }
        unit = nil
        isInitialized = false
        isRunning = false
        renderBuffer = nil
        handler = nil
        hardwareFormat = nil
        boundDeviceID = nil
    }

    var isCapturing: Bool { isRunning }

    /// The device this unit is actually bound to, for verifying the route did
    /// not change underneath the recording.
    func currentDeviceID() -> AudioDeviceID? {
        guard let unit else { return nil }
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            &size
        ) == noErr else { return nil }
        return deviceID
    }

    private func render(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        bus: UInt32,
        frames: UInt32
    ) -> OSStatus {
        guard let unit, let buffer = renderBuffer, let handler else { return noErr }
        guard frames <= buffer.frameCapacity else { return noErr }
        buffer.frameLength = frames
        let status = AudioUnitRender(
            unit,
            flags,
            timeStamp,
            bus,
            frames,
            buffer.mutableAudioBufferList
        )
        guard status == noErr else { return status }
        handler(buffer)
        return noErr
    }

    private func check(_ status: OSStatus, _ message: String) throws {
        guard status != noErr else { return }
        throw AudioRecordingError.audioSourceUnavailable(
            "\(message) (OSStatus \(status))"
        )
    }

    private static let inputBus: UInt32 = 1
    private static let outputBus: UInt32 = 0
    private static let maximumFrames: AVAudioFrameCount = 4_096
}
