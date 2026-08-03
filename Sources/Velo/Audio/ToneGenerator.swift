import AVFoundation
import Foundation

/// Test-tone source: a continuous stereo sine driven through AVAudioEngine for
/// speaker output and simultaneously injected into the AudioEngine's ring so the
/// visuals react exactly as they would to a real input.
///
/// Left and Right carry independent frequencies so the XY scope scenes trace
/// true Lissajous figures; set them equal for a centred mono tone.
///
/// Ported from Android's `ToneGenerator.kt` — same design: a dedicated audio
/// path that replaces the mic while active.
final class ToneGenerator {

    nonisolated(unsafe) var leftHz: Float = 440
    nonisolated(unsafe) var rightHz: Float = 440
    nonisolated(unsafe) var level: Float = 0.10

    private var avEngine: AVAudioEngine?
    private weak var audioEngine: AudioEngine?

    private var phaseL: Double = 0
    private var phaseR: Double = 0
    private var gain: Float = 0

    private let sampleRate: Double = 48_000
    private let gainSmooth: Float = 0.002

    var isRunning: Bool { avEngine?.isRunning ?? false }

    func start(audioEngine: AudioEngine) {
        stop()
        self.audioEngine = audioEngine
        audioEngine.stop()
        audioEngine.hasStereoSource = true
        audioEngine.injectedSource = InjectedSource(
            name: "test tone", sampleRate: sampleRate, channels: 2)

        let engine = AVAudioEngine()
        let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate, channels: 2)!

        phaseL = 0
        phaseR = 0
        gain = 0

        let sourceNode = AVAudioSourceNode(format: format) {
            [weak self] _, _, frameCount, bufferListPtr -> OSStatus in
            guard let self else { return noErr }

            let ablp = UnsafeMutableAudioBufferListPointer(bufferListPtr)
            let count = Int(frameCount)
            let target = min(max(self.level, 0), 1)
            let incL = Double(self.leftHz) / self.sampleRate
            let incR = Double(self.rightHz) / self.sampleRate

            guard let buf0 = ablp[0].mData?.assumingMemoryBound(to: Float.self) else {
                return noErr
            }
            let buf1: UnsafeMutablePointer<Float>
            if ablp.count > 1, let b = ablp[1].mData?.assumingMemoryBound(to: Float.self) {
                buf1 = b
            } else {
                buf1 = buf0
            }

            var pL = self.phaseL
            var pR = self.phaseR
            var g = self.gain

            let left = UnsafeMutablePointer<Float>.allocate(capacity: count)
            let right = UnsafeMutablePointer<Float>.allocate(capacity: count)
            defer { left.deallocate(); right.deallocate() }

            for i in 0..<count {
                g += (target - g) * self.gainSmooth
                let l = Float(sin(pL * .pi * 2)) * g
                let r = Float(sin(pR * .pi * 2)) * g
                buf0[i] = l
                buf1[i] = r
                left[i] = l
                right[i] = r
                pL = (pL + incL).truncatingRemainder(dividingBy: 1)
                pR = (pR + incR).truncatingRemainder(dividingBy: 1)
            }

            self.phaseL = pL
            self.phaseR = pR
            self.gain = g

            self.audioEngine?.injectStereoSamples(left: left, right: right, count: count)
            return noErr
        }

        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)

        do {
            try engine.start()
            avEngine = engine
        } catch {
            VeloLog.write("tone", "failed to start: \(error)")
            audioEngine.start()
        }
    }

    func stop() {
        avEngine?.stop()
        avEngine = nil
        if let engine = audioEngine {
            engine.hasStereoSource = false
            engine.injectedSource = nil
            engine.start()
            audioEngine = nil
        }
    }
}
