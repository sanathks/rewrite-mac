import AudioToolbox
import CoreAudio
import Foundation

/// Common surface for a system-audio capture backend so `MeetingTranscriber`
/// can hold one without being pinned to a specific macOS availability.
protocol SystemAudioCapturing: AnyObject {
    func start() async throws
    func stop() async
    func drainSamples() -> [Float]
    var onError: ((String) -> Void)? { get set }
}

/// Captures system audio (the remote side of a call) using Core Audio process
/// taps (macOS 14.2+). Unlike ScreenCaptureKit this uses the audio-only TCC
/// category (`NSAudioCaptureUsageDescription`) - no Screen Recording permission
/// and no purple menu-bar indicator. This is the approach Granola uses.
///
/// Output is 16 kHz mono Float32, matching `AudioCapture`, so it can be mixed.
@available(macOS 14.2, *)
final class CoreAudioTapCapture: SystemAudioCapturing {
    private var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    private let ioQueue = DispatchQueue(label: "com.rewrite.coreaudiotap")
    private let lock = NSLock()
    private var _samples: [Float] = []
    private var resampleOffset: Double = 0
    private var srcSampleRate: Double = 48_000

    private static let targetSampleRate: Double = 16_000

    var onError: ((String) -> Void)?

    struct TapError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: - Lifecycle

    func start() async throws {
        resetBuffer()

        // 1. Describe a global stereo tap over all system output.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.muteBehavior = .unmuted // never mute what the user hears
        description.name = "Rewrite Meeting Tap"
        description.isPrivate = true
        description.isMono = false

        // 2. Create the process tap. This triggers the audio-capture TCC prompt
        //    on first use (requires a stable signing identity).
        var tap = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(description, &tap)
        guard err == noErr, tap != kAudioObjectUnknown else {
            throw TapError(message: "Could not create audio tap (\(err)). Grant audio recording permission.")
        }
        tapID = tap

        // 3. Read the tap's stream format so we know sample rate / channels.
        srcSampleRate = readTapSampleRate(tap) ?? 48_000

        // 4. Wrap the tap in a private aggregate device we can run an IOProc on.
        let outputUID = defaultOutputDeviceUID()
        let aggUID = UUID().uuidString
        var aggDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Rewrite Aggregate",
            kAudioAggregateDeviceUIDKey as String: aggUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapDriftCompensationKey as String: true,
                    kAudioSubTapUIDKey as String: description.uuid.uuidString,
                ]
            ],
        ]
        if let outputUID {
            aggDescription[kAudioAggregateDeviceMainSubDeviceKey as String] = outputUID
            aggDescription[kAudioAggregateDeviceSubDeviceListKey as String] = [
                [kAudioSubDeviceUIDKey as String: outputUID]
            ]
        }

        var agg = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(aggDescription as CFDictionary, &agg)
        guard err == noErr, agg != kAudioObjectUnknown else {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
            throw TapError(message: "Could not create aggregate device (\(err)).")
        }
        aggregateID = agg

        // 5. Install an IOProc that receives the tapped audio.
        var procID: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&procID, agg, ioQueue) {
            [weak self] _, inInputData, _, _, _ in
            self?.handle(inputData: inInputData)
        }
        guard err == noErr, let procID else {
            teardown()
            throw TapError(message: "Could not install audio IO proc (\(err)).")
        }
        ioProcID = procID

        err = AudioDeviceStart(agg, procID)
        guard err == noErr else {
            teardown()
            throw TapError(message: "Could not start audio device (\(err)).")
        }
    }

    func stop() async {
        teardown()
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown, let procID = ioProcID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    func drainSamples() -> [Float] {
        lock.lock()
        let copy = _samples
        _samples = []
        lock.unlock()
        return copy
    }

    private func resetBuffer() {
        lock.lock()
        _samples = []
        resampleOffset = 0
        lock.unlock()
    }

    // MARK: - IO handling

    private func handle(inputData: UnsafePointer<AudioBufferList>) {
        let abl = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )
        guard abl.count > 0 else { return }

        var mono: [Float] = []
        if abl.count > 1 {
            // Non-interleaved: one buffer per channel.
            let frameCount = Int(abl[0].mDataByteSize) / MemoryLayout<Float>.size
            guard frameCount > 0 else { return }
            mono = [Float](repeating: 0, count: frameCount)
            var used = 0
            for buffer in abl {
                guard let data = buffer.mData else { continue }
                let ptr = data.assumingMemoryBound(to: Float.self)
                for i in 0..<frameCount { mono[i] += ptr[i] }
                used += 1
            }
            if used > 1 {
                let scale = 1.0 / Float(used)
                for i in 0..<frameCount { mono[i] *= scale }
            }
        } else {
            // Single buffer, possibly interleaved stereo.
            let buffer = abl[0]
            guard let data = buffer.mData else { return }
            let ch = Int(max(1, buffer.mNumberChannels))
            let totalFloats = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let frameCount = totalFloats / ch
            guard frameCount > 0 else { return }
            let ptr = data.assumingMemoryBound(to: Float.self)
            mono = [Float](repeating: 0, count: frameCount)
            for i in 0..<frameCount {
                var sum: Float = 0
                for c in 0..<ch { sum += ptr[i * ch + c] }
                mono[i] = sum / Float(ch)
            }
        }

        let resampled = resample(mono: mono)
        guard !resampled.isEmpty else { return }
        lock.lock()
        _samples.append(contentsOf: resampled)
        lock.unlock()
    }

    private func resample(mono: [Float]) -> [Float] {
        if Swift.abs(srcSampleRate - Self.targetSampleRate) < 1.0 { return mono }
        let ratio = srcSampleRate / Self.targetSampleRate
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

    // MARK: - Core Audio helpers

    private func readTapSampleRate(_ tap: AudioObjectID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let err = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd)
        guard err == noErr, asbd.mSampleRate > 0 else { return nil }
        return asbd.mSampleRate
    }

    private func defaultOutputDeviceUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard err == noErr, deviceID != 0 else { return nil }
        return SpeechService.deviceUID(for: deviceID)
    }

    deinit { teardown() }
}
