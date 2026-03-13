import AudioToolbox
import CoreAudio
import Foundation

/// Low-level audio capture using AudioUnit (HAL output) directly.
/// Avoids AVAudioEngine which triggers macOS audio routing reconfiguration
/// (causing a visible pause in video/audio playback).
/// The unit stays alive between recording sessions with a cooldown timer.
/// Samples are resampled to 16kHz mono Float32 for WhisperKit.
final class AudioCapture {
    fileprivate var audioUnit: AudioComponentInstance?
    private var isCapturing = false
    private var cooldownTimer: Timer?
    private var hwSampleRate: Double = 48000
    private var hwChannels: UInt32 = 1

    private static let cooldownSeconds: TimeInterval = 5
    private static let targetSampleRate: Double = 16000

    private let lock = NSLock()
    private var _samples: [Float] = []

    // Resampler state — tracks fractional position across callbacks
    private var resampleOffset: Double = 0

    var onAudioLevel: ((Float) -> Void)?

    var samples: [Float] {
        lock.lock()
        let copy = _samples
        lock.unlock()
        return copy
    }

    func drainSamples() -> [Float] {
        lock.lock()
        let copy = _samples
        _samples = []
        lock.unlock()
        return copy
    }

    func startCapture(deviceID: AudioDeviceID?) {
        cooldownTimer?.invalidate()
        cooldownTimer = nil

        lock.lock()
        _samples = []
        lock.unlock()
        resampleOffset = 0

        if audioUnit != nil {
            isCapturing = true
            return
        }

        guard let unit = createAudioUnit(deviceID: deviceID) else { return }
        audioUnit = unit
        isCapturing = true

        let status = AudioOutputUnitStart(unit)
        if status != noErr {
            disposeUnit()
        }
    }

    func stopCapture() {
        isCapturing = false

        cooldownTimer?.invalidate()
        cooldownTimer = Timer.scheduledTimer(
            withTimeInterval: Self.cooldownSeconds, repeats: false
        ) { [weak self] _ in
            self?.disposeUnit()
        }
    }

    private func disposeUnit() {
        cooldownTimer?.invalidate()
        cooldownTimer = nil
        if let unit = audioUnit {
            AudioOutputUnitStop(unit)
            AudioComponentInstanceDispose(unit)
        }
        audioUnit = nil
    }

    // MARK: - AudioUnit Setup

    private func createAudioUnit(deviceID: AudioDeviceID?) -> AudioComponentInstance? {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &desc) else { return nil }

        var unit: AudioComponentInstance?
        guard AudioComponentInstanceNew(component, &unit) == noErr,
              let unit = unit else { return nil }

        // Enable input (bus 1)
        var enableInput: UInt32 = 1
        AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input,
            1, // input bus
            &enableInput,
            UInt32(MemoryLayout<UInt32>.size)
        )

        // Disable output (bus 0)
        var disableOutput: UInt32 = 0
        AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output,
            0, // output bus
            &disableOutput,
            UInt32(MemoryLayout<UInt32>.size)
        )

        // Set input device
        let targetDevice = resolveDevice(deviceID)
        if targetDevice != 0 {
            var devID = targetDevice
            AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &devID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }

        // Query the device's native format
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var deviceFormat = AudioStreamBasicDescription()
        AudioUnitGetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            1,
            &deviceFormat,
            &formatSize
        )

        hwSampleRate = deviceFormat.mSampleRate > 0 ? deviceFormat.mSampleRate : 48000
        hwChannels = deviceFormat.mChannelsPerFrame > 0 ? deviceFormat.mChannelsPerFrame : 1

        // Request Float32 non-interleaved from the output scope of bus 1
        var outputFormat = AudioStreamBasicDescription(
            mSampleRate: hwSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: hwChannels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1,
            &outputFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )

        // Set input callback
        var callbackStruct = AURenderCallbackStruct(
            inputProc: audioInputCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global,
            0,
            &callbackStruct,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )

        guard AudioUnitInitialize(unit) == noErr else {
            AudioComponentInstanceDispose(unit)
            return nil
        }

        return unit
    }

    private func resolveDevice(_ deviceID: AudioDeviceID?) -> AudioDeviceID {
        if let deviceID = deviceID, deviceID != 0 {
            return deviceID
        }
        // Get default input device
        var defaultDevice: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0, nil,
            &size,
            &defaultDevice
        )
        return defaultDevice
    }

    // MARK: - Audio Callback

    fileprivate func processAudio(
        inUnit: AudioComponentInstance,
        ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        inTimeStamp: UnsafePointer<AudioTimeStamp>,
        inBusNumber: UInt32,
        inNumberFrames: UInt32
    ) {
        guard isCapturing else { return }

        // Allocate buffer list for rendering
        let channelCount = Int(hwChannels)
        let frameCount = Int(inNumberFrames)

        let bufferListSize = AudioBufferList.sizeInBytes(maximumBuffers: channelCount)
        let bufferListPtr = UnsafeMutablePointer<AudioBufferList>.allocate(
            capacity: bufferListSize
        )
        defer { bufferListPtr.deallocate() }

        var buffers = [UnsafeMutablePointer<Float>]()
        bufferListPtr.pointee.mNumberBuffers = UInt32(channelCount)

        let ablPointer = UnsafeMutableAudioBufferListPointer(bufferListPtr)
        for i in 0..<channelCount {
            let buf = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
            buffers.append(buf)
            ablPointer[i] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(frameCount * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(buf)
            )
        }
        defer { buffers.forEach { $0.deallocate() } }

        let status = AudioUnitRender(
            inUnit, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, bufferListPtr
        )
        guard status == noErr else { return }

        // Mix to mono
        var mono = [Float](repeating: 0, count: frameCount)
        if channelCount == 1 {
            memcpy(&mono, buffers[0], frameCount * MemoryLayout<Float>.size)
        } else {
            for ch in 0..<channelCount {
                let ptr = buffers[ch]
                for i in 0..<frameCount {
                    mono[i] += ptr[i]
                }
            }
            let scale = 1.0 / Float(channelCount)
            for i in 0..<frameCount { mono[i] *= scale }
        }

        // Resample to 16kHz
        let resampled: [Float]
        if abs(hwSampleRate - Self.targetSampleRate) < 1.0 {
            resampled = mono
        } else {
            resampled = resample(mono: mono)
        }

        guard !resampled.isEmpty else { return }

        lock.lock()
        _samples.append(contentsOf: resampled)
        lock.unlock()

        // RMS for waveform
        var sumSq: Float = 0
        for s in resampled { sumSq += s * s }
        let rms = sqrt(sumSq / Float(resampled.count))
        let level = min(1.0, rms * 8.0)
        DispatchQueue.main.async { [weak self] in
            self?.onAudioLevel?(level)
        }
    }

    private func resample(mono: [Float]) -> [Float] {
        let ratio = hwSampleRate / Self.targetSampleRate
        let frameCount = mono.count
        var output = [Float]()
        output.reserveCapacity(Int(Double(frameCount) / ratio) + 1)

        var pos = resampleOffset
        while pos < Double(frameCount) {
            let idx = Int(pos)
            let frac = Float(pos - Double(idx))
            if idx + 1 < frameCount {
                output.append(mono[idx] * (1.0 - frac) + mono[idx + 1] * frac)
            } else {
                output.append(mono[min(idx, frameCount - 1)])
            }
            pos += ratio
        }
        resampleOffset = pos - Double(frameCount)
        return output
    }

    deinit {
        disposeUnit()
    }
}

// C callback — bridges to the AudioCapture instance
private func audioInputCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let capture = Unmanaged<AudioCapture>.fromOpaque(inRefCon).takeUnretainedValue()
    capture.processAudio(
        inUnit: capture.audioUnit!,
        ioActionFlags: ioActionFlags,
        inTimeStamp: inTimeStamp,
        inBusNumber: inBusNumber,
        inNumberFrames: inNumberFrames
    )
    return noErr
}
