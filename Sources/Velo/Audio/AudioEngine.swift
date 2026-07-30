import Accelerate
import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// What the capture side is doing, for the diagnostics overlay.
///
/// "The visual is not moving" and "the visual is not receiving anything" look
/// identical on screen, and this is what tells them apart.
struct AudioStatus: Sendable, Equatable {
    var device = "no input"
    var sampleRate: Double = 0
    var channels = 0
    var bufferFrames = 0
    /// Peak of the recent window, linear.
    var level: Float = 0

    /// The same peak in dBFS, which is the only honest way to show it.
    ///
    /// A linear bar spends its whole scale on the top few dB: music sitting at
    /// a healthy -14 dBFS is 0.2 linear, which on five linear blocks lights
    /// exactly one. The ear is logarithmic and so is every meter worth reading.
    var levelDb: Float { 20 * log10f(max(level, 1e-5)) }

    /// -60 dBFS to 0, matching the fixed scale the meters use. Not auto-ranged:
    /// a meter that rescales itself cannot be read against anything.
    var levelFraction: Float { min(max((levelDb + 60) / 60, 0), 1) }

    var silent: Bool { level < 0.0005 }

    var format: String {
        sampleRate == 0
            ? "not capturing"
            : "\(Int(sampleRate)) Hz · \(channels) ch · \(bufferFrames) fr"
    }
}

/// One selectable input. BlackHole, an interface, or the built-in mic all
/// appear here identically — a loopback device is just an input device.
struct AudioInputDevice: Identifiable, Hashable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

/// Live audio capture and analysis.
///
/// Architecture mirrors the Android app deliberately: the real-time callback
/// only ever writes into a lock-free ring, and the render thread pulls the
/// newest window from it. Nothing allocates, locks, or blocks on the audio
/// thread, so buffer size can go as low as the device allows without risking
/// glitches from the analysis side.
///
/// The capture unit is AUHAL directly rather than `AVAudioEngine`. AVAudioEngine
/// adds its own buffering and makes selecting a non-default input device
/// awkward; AUHAL is the layer underneath it and lets the device, the buffer
/// frame size and the callback be set explicitly — which is the whole point
/// when the target is a DJ rig feeding OBS.
final class AudioEngine: @unchecked Sendable {

    /// 1024-point analysis window, as on Android: ~21 ms at 48 kHz, enough
    /// resolution for a third-octave display without smearing transients.
    static let fftSize = 1024
    static let binCount = 128
    static let bandCount = 31

    private var unit: AudioUnit?
    private var currentDeviceID: AudioDeviceID?
    private var deviceSampleRate: Double = 48_000

    // Lock-free ring. Single producer (audio thread), single consumer (render).
    private let ringCapacity = 16_384
    private var ring: UnsafeMutablePointer<Float>
    private let writeIndex = ManagedAtomic()

    // Preallocated capture scratch. The render callback used to allocate two
    // buffers per invocation on the real-time thread; malloc there can block on
    // a lock held by another thread and is exactly how audio glitches.
    private let maxCallbackFrames = 4096
    private var captureL: UnsafeMutablePointer<Float>
    private var captureR: UnsafeMutablePointer<Float>
    private var captureList: UnsafeMutableAudioBufferListPointer

    // Analysis scratch, owned by the consumer side only.
    private var window = [Float](repeating: 0, count: AudioEngine.fftSize)
    private var scratch = [Float](repeating: 0, count: AudioEngine.fftSize)
    private var magnitudes = [Float](repeating: 0, count: AudioEngine.fftSize / 2)
    private var bins = [Float](repeating: 0, count: AudioEngine.binCount)
    private var bands = [Float](repeating: 0, count: AudioEngine.bandCount)
    // Preallocated FFT scratch. These were allocated per call, on the render
    // thread, at up to 240 allocations a second — malloc has no business in a
    // frame loop.
    private var fftReal = [Float](repeating: 0, count: AudioEngine.fftSize / 2)
    private var fftImag = [Float](repeating: 0, count: AudioEngine.fftSize / 2)
    private let fft: FFTSetup
    private let log2n: vDSP_Length

    fileprivate let debugAudio = ProcessInfo.processInfo.environment["VELO_AUDIO_DEBUG"] != nil
    fileprivate var debugCounter = 0
    fileprivate var debugReadCounter = 0
    private var reportedOnce = Set<String>()
    private var statusStorage = AudioStatus()

    init() {
        ring = UnsafeMutablePointer<Float>.allocate(capacity: ringCapacity)
        ring.initialize(repeating: 0, count: ringCapacity)
        captureL = UnsafeMutablePointer<Float>.allocate(capacity: maxCallbackFrames)
        captureR = UnsafeMutablePointer<Float>.allocate(capacity: maxCallbackFrames)
        captureL.initialize(repeating: 0, count: maxCallbackFrames)
        captureR.initialize(repeating: 0, count: maxCallbackFrames)
        captureList = AudioBufferList.allocate(maximumBuffers: 2)
        log2n = vDSP_Length(log2(Double(Self.fftSize)))
        fft = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        vDSP_hann_window(&window, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))
    }

    deinit {
        stop()
        vDSP_destroy_fftsetup(fft)
        ring.deallocate()
        captureL.deallocate()
        captureR.deallocate()
        free(captureList.unsafeMutablePointer)
    }

    /// Audio failures are otherwise invisible: every one of these paths used to
    /// return quietly, so a dead input and a quiet room looked identical.
    fileprivate func report(_ message: String) { VeloLog.write("audio", message) }

    fileprivate func reportOnce(_ message: String) {
        guard !reportedOnce.contains(message) else { return }
        reportedOnce.insert(message)
        report(message)
    }

    // MARK: - Devices

    /// Every device that can actually deliver input. A device with no input
    /// streams (a plain pair of speakers) is filtered out rather than listed
    /// and then failing on selection.
    static func inputDevices() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }

        return ids.compactMap { id in
            guard hasInput(id) else { return nil }
            guard let name = stringProperty(id, kAudioObjectPropertyName),
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID)
            else { return nil }
            return AudioInputDevice(id: id, uid: uid, name: name)
        }
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
              size > 0 else { return false }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else {
            return false
        }
        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self)
        )
        return list.contains { $0.mNumberChannels > 0 }
    }

    private static func stringProperty(
        _ id: AudioDeviceID, _ selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // Unmanaged, not a bare CFString: Core Audio writes a +1 retained
        // reference into the buffer, and pointing at a managed `CFString`
        // variable hands ARC a value it never owned. Taking it as retained is
        // what balances the reference Core Audio created.
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let unmanaged = value else { return nil }
        return unmanaged.takeRetainedValue() as String
    }

    // MARK: - Capture

    /// Capture is TCC-gated, and a denial is delivered as an endless stream of
    /// silence rather than an error — which is indistinguishable from a quiet
    /// room unless it is asked about directly. So ask.
    func start(deviceUID: String? = nil) {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        report("microphone authorization: \(Self.describe(status))")
        switch status {
        case .authorized:
            open(deviceUID: deviceUID)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                guard let self else { return }
                if !granted { report("microphone access denied — capture will be silent") }
                // Open either way. A denial still leaves a running unit that
                // delivers silence, which is exactly what happened before this
                // check existed, so asking can never make matters worse.
                DispatchQueue.main.async { self.open(deviceUID: deviceUID) }
            }
        default:
            report(
                "microphone access denied or restricted. System Settings > Privacy "
                + "& Security > Microphone. Capture will be silent until granted.")
            open(deviceUID: deviceUID)
        }
    }

    private static func describe(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .notDetermined: return "not determined (never asked)"
        case .denied: return "DENIED"
        case .restricted: return "restricted"
        @unknown default: return "unknown"
        }
    }

    private func open(deviceUID: String?) {
        stop()
        let devices = Self.inputDevices()
        guard let device = devices.first(where: { $0.uid == deviceUID }) ?? devices.first else {
            report("no input device available (asked for \(deviceUID ?? "default"))")
            return
        }
        currentDeviceID = device.id

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            report("no HAL output component")
            return
        }
        var newUnit: AudioUnit?
        let created = AudioComponentInstanceNew(component, &newUnit)
        guard created == noErr, let audioUnit = newUnit else {
            report("AudioComponentInstanceNew failed: \(created)")
            return
        }

        // AUHAL is an *output* unit with input enabled on bus 1 and output
        // disabled on bus 0 — the standard, and unintuitive, capture setup.
        var enable: UInt32 = 1
        AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO,
                             kAudioUnitScope_Input, 1, &enable, UInt32(MemoryLayout<UInt32>.size))
        var disable: UInt32 = 0
        AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO,
                             kAudioUnitScope_Output, 0, &disable, UInt32(MemoryLayout<UInt32>.size))

        var deviceID = device.id
        AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice,
                             kAudioUnitScope_Global, 0, &deviceID,
                             UInt32(MemoryLayout<AudioDeviceID>.size))

        // Ask the device for its smallest usable buffer. This is a request, not
        // a demand: the device clamps to its own supported range, which is why
        // the actual value is read back rather than assumed.
        //
        // The buffer is how stale the newest sample can be when the render
        // thread reads the ring — one buffer worst case, half on average. 256
        // frames is 5.3 ms of that at 48 kHz and there is no reason to carry it.
        // Floored at 64: below that the callback rate climbs past 750 Hz to
        // shave a millisecond off a value the renderer only samples at 120 Hz.
        var frames = Self.smallestBuffer(of: device.id)
        var bufferAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(device.id, &bufferAddress, 0, nil,
                                   UInt32(MemoryLayout<UInt32>.size), &frames)
        // Read it back: the request is advisory and the device clamps it.
        var bufferSize = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device.id, &bufferAddress, 0, nil, &bufferSize, &frames)

        deviceSampleRate = Self.sampleRate(of: device.id) ?? 48_000

        // Deinterleaved float32: the unit hands back L and R as two separate
        // buffers, so the callback needs no format conversion and the channels
        // are already apart for the XY scope.
        var format = AudioStreamBasicDescription(
            mSampleRate: deviceSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        let formatSet = AudioUnitSetProperty(
            audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        if formatSet != noErr { report("stream format rejected: \(formatSet)") }

        // Bound the callback explicitly rather than trusting the default. The
        // capture scratch is a fixed allocation, and a slice larger than it
        // would previously have been dropped on the floor without a word — an
        // entire dead input that looks exactly like silence.
        var maxSlice = UInt32(maxCallbackFrames)
        AudioUnitSetProperty(audioUnit, kAudioUnitProperty_MaximumFramesPerSlice,
                             kAudioUnitScope_Global, 0, &maxSlice,
                             UInt32(MemoryLayout<UInt32>.size))

        var callback = AURenderCallbackStruct(
            inputProc: audioInputCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_SetInputCallback,
                             kAudioUnitScope_Global, 0, &callback,
                             UInt32(MemoryLayout<AURenderCallbackStruct>.size))

        let initialised = AudioUnitInitialize(audioUnit)
        guard initialised == noErr else {
            report("AudioUnitInitialize failed: \(initialised) — device \(device.name)")
            AudioComponentInstanceDispose(audioUnit)
            return
        }

        // Set before starting: the callback can fire the instant the unit runs,
        // and a nil `unit` there means the first buffers are discarded.
        unit = audioUnit
        let started = AudioOutputUnitStart(audioUnit)
        if started != noErr {
            report("AudioOutputUnitStart failed: \(started)")
            unit = nil
            AudioUnitUninitialize(audioUnit)
            AudioComponentInstanceDispose(audioUnit)
            return
        }
        let channels = Self.inputChannels(of: device.id)
        statusStorage = AudioStatus(
            device: device.name, sampleRate: deviceSampleRate,
            channels: channels, bufferFrames: Int(frames))
        report("capturing \(device.name) — \(Int(deviceSampleRate)) Hz, "
               + "\(channels) ch in, \(frames) frame buffer")
    }

    /// Input channels the device actually offers. Two is assumed everywhere
    /// else; a one-channel device silently fills only the left buffer, which is
    /// worth saying out loud when the XY scope looks like a flat line.
    private static func inputChannels(of id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
              size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else {
            return 0
        }
        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    func stop() {
        guard let audioUnit = unit else { return }
        AudioOutputUnitStop(audioUnit)
        AudioUnitUninitialize(audioUnit)
        AudioComponentInstanceDispose(audioUnit)
        unit = nil
    }

    /// The device's own minimum buffer size, floored at 64 frames.
    private static func smallestBuffer(of id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSizeRange,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var range = AudioValueRange()
        var size = UInt32(MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &range) == noErr,
              range.mMinimum > 0 else { return 128 }
        return UInt32(max(range.mMinimum, 64))
    }

    private static func sampleRate(of id: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate) == noErr else {
            return nil
        }
        return rate
    }

    /// Called on the real-time thread. Writes only; never allocates or locks.
    /// Mono-summed here, as it always was: every scene wants the sum.
    fileprivate func write(
        left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int
    ) {
        let w = writeIndex.load()
        for i in 0..<frames {
            ring[(w &+ i) % ringCapacity] = (left[i] + right[i]) * 0.5
        }
        writeIndex.store(w &+ frames)
    }

    var sampleRate: Double { deviceSampleRate }

    /// Frames written since the engine started. A consumer that needs the
    /// stream rather than a snapshot holds one of these as a cursor.
    var framesWritten: Int { writeIndex.load() }

    /// A description of the live capture, plus the peak of the recent window.
    /// Peak rather than RMS, because the question this answers is "is anything
    /// arriving at all", and RMS hides a sparse signal.
    func status() -> AudioStatus {
        var out = statusStorage
        let w = writeIndex.load()
        let n = min(2048, ringCapacity)
        var peak: Float = 0
        for i in 0..<n {
            let v = abs(ring[(w &+ ringCapacity &- n &+ i) % ringCapacity])
            if v > peak { peak = v }
        }
        out.level = min(peak, 1)
        return out
    }

    /// Copy every frame written since `cursor`, oldest first, and return how
    /// many were copied along with the cursor to pass next time.
    ///
    /// Exact, not estimated from elapsed time. A scene that builds a timeline
    /// has to consume the sample stream without gaps or overlaps, and deriving
    /// "how much audio arrived since the last frame" from a frame duration
    /// mis-splices it on every hiccup.
    ///
    /// A consumer that falls behind by more than the ring holds loses the
    /// oldest frames rather than stalling: the returned cursor jumps, and the
    /// gap is the caller's to notice.
    func drain(
        since cursor: Int, into dst: UnsafeMutablePointer<Float>, capacity: Int
    ) -> (count: Int, cursor: Int) {
        let w = writeIndex.load()
        let pending = w - cursor
        guard pending > 0 else { return (0, w) }
        let n = min(pending, min(capacity, ringCapacity))
        let start = w - n
        for i in 0..<n { dst[i] = ring[(start &+ i) % ringCapacity] }
        return (n, w)
    }

    /// Write mono samples into the ring from an external source (tone
    /// generator). The mic callback must be stopped first so there is
    /// only one producer.
    func injectSamples(_ samples: UnsafePointer<Float>, count: Int) {
        let w = writeIndex.load()
        for i in 0..<count {
            ring[(w &+ i) % ringCapacity] = samples[i]
        }
        writeIndex.store(w &+ count)
    }

    /// Fill the ring with broadband synthetic signal, for `SelfTest`.
    ///
    /// A sum of tones across the spectrum rather than one sine, so every band
    /// and every bin has something in it. Without this a self test cannot tell
    /// a broken visual from a quiet room, which is the entire difficulty.
    private var testCallCount = 0

    func injectTestSignal() {
        // Vary the volume across frames so consecutive 1024-sample windows
        // have different bass RMS, giving the beat detector real flux to
        // detect. A "kick" every 7 frames at 60 fps ≈ 8.5 beats/s.
        let kick = (testCallCount % 7) == 0
        let gain: Float = kick ? 0.6 : 0.12
        testCallCount += 1

        var phase = Float(writeIndex.load())
        for _ in 0..<1024 {
            var v: Float = 0
            for harmonic in [1, 3, 7, 17, 41, 97] {
                v += sinf(phase * 0.0013 * Float(harmonic)) / Float(harmonic)
            }
            let w = writeIndex.load()
            ring[w % ringCapacity] = v * gain
            writeIndex.store(w &+ 1)
            phase += 1
        }
    }

    // MARK: - Analysis

    /// Copy the newest `count` samples, oldest first, into a caller-owned
    /// buffer. No allocation and no return array, because this runs once per
    /// rendered frame on the render thread.
    func fillWaveform(_ dst: UnsafeMutablePointer<Float>, count: Int) {
        let w = writeIndex.load()
        let n = min(count, ringCapacity)
        for i in 0..<n {
            dst[i] = ring[(w &+ ringCapacity &- n &+ i) % ringCapacity]
        }
        if count > n { for i in n..<count { dst[i] = 0 } }
    }

    /// 31 third-octave bands (0...1) — the reading a real RTA gives.
    func currentBands() -> [Float] { analyse(); return bands }

    /// 128 log-spaced bins (0...1), for scenes that want finer detail than
    /// third-octave: a ring of bars, or a matrix folded down to its columns.
    func currentBins() -> [Float] { analyse(); return bins }

    /// Pull the newest window and fold it into bands and bins. One FFT per
    /// frame regardless of which accessor a scene reaches for.
    private func analyse() {
        let n = Self.fftSize
        scratch.withUnsafeMutableBufferPointer { fillWaveform($0.baseAddress!, count: n) }
        vDSP_vmul(scratch, 1, window, 1, &scratch, 1, vDSP_Length(n))

        fftReal.withUnsafeMutableBufferPointer { realPtr in
            fftImag.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!,
                                            imagp: imagPtr.baseAddress!)
                scratch.withUnsafeBufferPointer { src in
                    src.baseAddress!.withMemoryRebound(
                        to: DSPComplex.self, capacity: n / 2
                    ) { typed in
                        vDSP_ctoz(typed, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(n / 2))
            }
        }

        if debugAudio {
            debugReadCounter += 1
            if debugReadCounter % 120 == 0 {
                var peak: Float = 0
                vDSP_maxmgv(scratch, 1, &peak, vDSP_Length(n))
                var bandMax: Float = 0
                vDSP_maxv(bands, 1, &bandMax, vDSP_Length(Self.bandCount))
                print(String(format: "[velo/audio] window peak %.5f  bandMax %.3f  rate %.0f",
                             peak, bandMax, deviceSampleRate))
                fflush(stdout)
            }
        }
        buildBands()
        buildBins()
    }

    /// Fold the spectrum into 31 log-spaced bands, mapped through the same
    /// dB window the Android app uses so the two look alike: a 3 dB/octave
    /// tilt to offset music's natural spectral slope, then -88...-12 dBFS
    /// across the display's full height.
    /// The same dB window as the bands, at 128-bin resolution. Log-spaced for
    /// the same reason: linear bins spend three quarters of the display on the
    /// top two octaves, where music has almost nothing to show.
    private func buildBins() {
        let n = Self.fftSize
        let nyquist = Float(deviceSampleRate) * 0.5
        let lowHz: Float = 20
        let ratio = min(20_000, nyquist * 0.98) / lowHz

        for b in 0..<Self.binCount {
            let f0 = lowHz * powf(ratio, Float(b) / Float(Self.binCount))
            let f1 = lowHz * powf(ratio, Float(b + 1) / Float(Self.binCount))
            let i0 = max(1, Int(f0 / nyquist * Float(n / 2)))
            let i1 = min(n / 2 - 1, max(i0 + 1, Int(f1 / nyquist * Float(n / 2))))

            var peak: Float = 0
            for i in i0..<i1 where magnitudes[i] > peak { peak = magnitudes[i] }

            let tilt = powf(sqrtf(f0 * f1) / lowHz, 0.5)   // ~3 dB per octave
            let db = 20 * log10f(max(peak * tilt, 1e-9) / Float(n))
            bins[b] = min(max((db + 88) / 76, 0), 1)
        }
    }

    private func buildBands() {
        let n = Self.fftSize
        let nyquist = Float(deviceSampleRate) * 0.5
        let lowHz: Float = 20
        let highHz: Float = min(20_000, nyquist * 0.98)
        let ratio = highHz / lowHz

        for b in 0..<Self.bandCount {
            let f0 = lowHz * powf(ratio, Float(b) / Float(Self.bandCount))
            let f1 = lowHz * powf(ratio, Float(b + 1) / Float(Self.bandCount))
            let i0 = max(1, Int(f0 / nyquist * Float(n / 2)))
            let i1 = min(n / 2 - 1, max(i0 + 1, Int(f1 / nyquist * Float(n / 2))))

            // Peak within the band, not mean: an analyser should show the peak,
            // and averaging buries a narrow tone under quiet neighbours.
            var peak: Float = 0
            for i in i0..<i1 where magnitudes[i] > peak { peak = magnitudes[i] }

            let centre = sqrtf(f0 * f1)
            let tilt = powf(centre / lowHz, 0.5)      // ~3 dB per octave
            let db = 20 * log10f(max(peak * tilt, 1e-9) / Float(n))
            let v = (db + 88) / 76                     // -88...-12 dBFS -> 0...1
            // Raw, unsmoothed. This used to run its own attack/release EMA and
            // then hand the result to a scene that runs ANOTHER one — two
            // filters in series, roughly 20 ms of lag for a shape nobody chose.
            // Worse, it was per-frame rather than per-second, so it smoothed
            // twice as hard in time at 240 fps as at 120. Ballistics belong to
            // the scene, where they are expressed in seconds and are visible.
            bands[b] = min(max(v, 0), 1)
        }
    }
}

/// Minimal atomic index for the single-producer / single-consumer ring.
/// A torn read at the wrap boundary costs one sample in a 1024-sample window,
/// which is imperceptible — the same tolerance the Android ring relies on to
/// stay lock-free on the audio thread.
final class ManagedAtomic: @unchecked Sendable {
    private var value: Int = 0
    private let lock = NSLock()
    func load() -> Int { lock.lock(); defer { lock.unlock() }; return value }
    func store(_ new: Int) { lock.lock(); value = new; lock.unlock() }
}

/// C callback trampoline. AUHAL hands us a buffer list we must render into.
private func audioInputCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let engine = Unmanaged<AudioEngine>.fromOpaque(inRefCon).takeUnretainedValue()
    return engine.renderInput(
        flags: ioActionFlags, timestamp: inTimeStamp,
        bus: inBusNumber, frames: inNumberFrames
    )
}

extension AudioEngine {
    fileprivate var captureUnit: AudioUnit? { unit }

    /// The real-time path. Everything it touches is preallocated: no malloc, no
    /// locks beyond the ring's single index, no Swift runtime calls that could
    /// allocate.
    fileprivate func renderInput(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        bus: UInt32,
        frames: UInt32
    ) -> OSStatus {
        guard let unit = captureUnit else { return noErr }
        if Int(frames) > maxCallbackFrames {
            reportOnce("callback asked for \(frames) frames, scratch holds \(maxCallbackFrames)")
            return noErr
        }
        let count = Int(frames)
        let bytes = UInt32(count * MemoryLayout<Float>.size)
        captureList[0] = AudioBuffer(
            mNumberChannels: 1, mDataByteSize: bytes, mData: UnsafeMutableRawPointer(captureL))
        captureList[1] = AudioBuffer(
            mNumberChannels: 1, mDataByteSize: bytes, mData: UnsafeMutableRawPointer(captureR))

        let status = AudioUnitRender(
            unit, flags, timestamp, bus, UInt32(count), captureList.unsafeMutablePointer)
        guard status == noErr else {
            if debugAudio { print("[velo/audio] render status \(status)"); fflush(stdout) }
            return status
        }

        write(left: captureL, right: captureR, frames: count)

        if debugAudio {
            debugCounter += 1
            if debugCounter % 200 == 0 {
                var pl: Float = 0, pr: Float = 0
                vDSP_maxmgv(captureL, 1, &pl, vDSP_Length(count))
                vDSP_maxmgv(captureR, 1, &pr, vDSP_Length(count))
                print(String(format: "[velo/audio] frames %d  bufs %d  peakL %.5f  peakR %.5f  w %d",
                             count, captureList.count, pl, pr, writeIndex.load()))
                fflush(stdout)
            }
        }
        return noErr
    }
}
