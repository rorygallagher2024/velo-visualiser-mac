import Foundation
import Metal

/// Nine seconds of waveform history, built from the sample stream.
///
/// Ported from Android's `BandWaveHistory`. Feeds the Waveform visual, and is
/// separate from it because it is a data model rather than a look.
///
/// Columns are built from the ACTUAL sample stream, not from a snapshot taken
/// each frame. A column completes on a sample boundary, so it can never commit
/// half full, and the timeline never gains or loses time.
///
/// Each ~2.3 ms column stores the signed min and max of the signal, plus the
/// peak of three band envelopes split by Linkwitz-Riley crossovers at 200 Hz
/// and 2 kHz. Storing band envelopes rather than an FFT tint matters: the
/// spectrum at commit time is smeared across the whole analysis window, while
/// the envelopes are the filtered audio at that instant. A kick and a hat in
/// one column become two different shapes rather than a blended hue.
final class WaveHistory {

    static let slices = 4096
    /// The visible span. 3840 columns at 2.34 ms is nine seconds.
    static let visible = 3840
    static let sliceSeconds: Float = 9.0 / 3840.0
    /// lo, mid, hi, up, down, mark
    static let fields = 6

    private(set) var head = 0
    private var buffer: MTLBuffer?
    var gpuBuffer: MTLBuffer? { buffer }

    // Per-column accumulators.
    private var samplesInSlice: Float = 0
    private var slicePeriod: Float = 100
    private var sliceMax: Float = -1
    private var sliceMin: Float = 1
    private var sliceLo: Float = 0
    private var sliceMid: Float = 0
    private var sliceHi: Float = 0

    // Auto-gain. Rises fast so loud material settles inside the frame, falls
    // slowly so a breakdown stays visibly smaller than the drop before it.
    private var agcRef: Float = amplitudeFloor

    private var cursor = 0
    private var scratch = [Float](repeating: 0, count: 8192)
    private var configuredRate: Float = 0

    private var lowLp1 = Biquad(), lowLp2 = Biquad()
    private var midHp1 = Biquad(), midHp2 = Biquad()
    private var midLp1 = Biquad(), midLp2 = Biquad()
    private var hiHp1 = Biquad(), hiHp2 = Biquad()

    private static let amplitudeTarget: Float = 0.85
    /// Soft knee, which fattens quiet detail without letting peaks clip.
    private static let amplitudeKnee: Float = 0.85
    private static let agcRise: Float = 0.20
    /// About a 25 second half-life at 2.3 ms per column.
    private static let agcFallPerSlice: Float = 0.999935
    private static let amplitudeFloor: Float = 0.02
    private static let crossoverLowHz: Float = 200
    private static let crossoverHighHz: Float = 2000
    /// Band slivers below this are crossover leakage, not signal.
    private static let gateLow: Float = 0.05
    private static let gateHigh: Float = 0.12

    func prepare(device: MTLDevice) {
        buffer = device.makeBuffer(
            length: Self.slices * Self.fields * MemoryLayout<Float>.stride,
            options: .storageModeShared)
    }

    /// Pull everything the engine has produced since the last call and fold it
    /// into columns.
    func consume(audio: AudioEngine) {
        guard buffer != nil else { return }
        configure(rate: Float(max(audio.sampleRate, 8000)))

        // First call: start at the present rather than draining the whole ring
        // as if it were history that had scrolled past.
        if cursor == 0 { cursor = audio.framesWritten }

        let drained = scratch.withUnsafeMutableBufferPointer { dst in
            audio.drain(since: cursor, into: dst.baseAddress!, capacity: dst.count)
        }
        cursor = drained.cursor
        for i in 0..<drained.count { accumulate(drained.count > 0 ? scratch[i] : 0) }
    }

    private func configure(rate: Float) {
        guard rate != configuredRate else { return }
        configuredRate = rate
        slicePeriod = max(rate * Self.sliceSeconds, 1)
        lowLp1.lowPass(Self.crossoverLowHz, rate); lowLp2.lowPass(Self.crossoverLowHz, rate)
        midHp1.highPass(Self.crossoverLowHz, rate); midHp2.highPass(Self.crossoverLowHz, rate)
        midLp1.lowPass(Self.crossoverHighHz, rate); midLp2.lowPass(Self.crossoverHighHz, rate)
        hiHp1.highPass(Self.crossoverHighHz, rate); hiHp2.highPass(Self.crossoverHighHz, rate)
    }

    private func accumulate(_ sample: Float) {
        sliceMax = max(sliceMax, sample)
        sliceMin = min(sliceMin, sample)

        // Three-way crossover. Independent cascaded pairs rather than a
        // subtractive split: subtracting one band from another leaks through
        // PHASE rather than through slope, and a tone lands in two bands at
        // once.
        let lo = lowLp2.process(lowLp1.process(sample))
        let mid = midLp2.process(midLp1.process(midHp2.process(midHp1.process(sample))))
        let hi = hiHp2.process(hiHp1.process(sample))
        sliceLo = max(sliceLo, abs(lo))
        sliceMid = max(sliceMid, abs(mid))
        sliceHi = max(sliceHi, abs(hi))

        samplesInSlice += 1
        if samplesInSlice >= slicePeriod {
            // Carry the remainder rather than resetting, so the column rate
            // does not drift against the sample rate.
            samplesInSlice -= slicePeriod
            commit()
        }
    }

    private func commit() {
        // Mono source, so this is the classic min/max waveform. The stereo
        // split Android does needs L and R apart, which this engine's ring
        // does not carry.
        let up = max(sliceMax, 0)
        let down = max(-sliceMin, 0)
        let peak = max(up, down)

        agcRef = peak > agcRef
            ? agcRef + (peak - agcRef) * Self.agcRise
            : max(agcRef * Self.agcFallPerSlice, max(peak, Self.amplitudeFloor))
        let norm = 1 / max(agcRef, Self.amplitudeFloor)

        // The band envelopes share the master normalisation, so their heights
        // stay honestly proportional to each other and to the outline.
        let store = buffer!.contents()
            .advanced(by: head * Self.fields * MemoryLayout<Float>.stride)
            .assumingMemoryBound(to: Float.self)
        store[0] = gate(display(sliceLo, norm))
        store[1] = gate(display(sliceMid, norm))
        store[2] = gate(display(sliceHi, norm))
        store[3] = display(up, norm)
        store[4] = display(down, norm)
        store[5] = 0                       // beat mark, unused without Link

        head = (head + 1) % Self.slices
        sliceMax = -1; sliceMin = 1
        sliceLo = 0; sliceMid = 0; sliceHi = 0
    }

    private func display(_ v: Float, _ norm: Float) -> Float {
        pow(min(v * norm * Self.amplitudeTarget, 1), Self.amplitudeKnee)
    }

    /// Smoothly zero band slivers below a few percent of the frame. Even a
    /// 24 dB per octave crossover leaks a little, and the auto-gain's soft knee
    /// would lift that residue into a visible phantom curtain on a pure tone.
    private func gate(_ v: Float) -> Float {
        let t = min(max((v - Self.gateLow) / (Self.gateHigh - Self.gateLow), 0), 1)
        return v * t * t * (3 - 2 * t)
    }
}

/// One RBJ biquad section at Butterworth Q. Two cascaded make one
/// Linkwitz-Riley fourth-order crossover edge. Direct form II transposed.
private struct Biquad {
    private var b0: Float = 1, b1: Float = 0, b2: Float = 0
    private var a1: Float = 0, a2: Float = 0
    private var z1: Float = 0, z2: Float = 0

    private static let butterworthQ: Float = 0.70710678

    mutating func lowPass(_ fc: Float, _ rate: Float) {
        let c = cosf(2 * .pi * fc / rate)
        configure((1 - c) * 0.5, 1 - c, (1 - c) * 0.5, c, fc, rate)
    }

    mutating func highPass(_ fc: Float, _ rate: Float) {
        let c = cosf(2 * .pi * fc / rate)
        configure((1 + c) * 0.5, -(1 + c), (1 + c) * 0.5, c, fc, rate)
    }

    private mutating func configure(
        _ nb0: Float, _ nb1: Float, _ nb2: Float, _ c: Float, _ fc: Float, _ rate: Float
    ) {
        let alpha = sinf(2 * .pi * fc / rate) / (2 * Self.butterworthQ)
        let a0 = 1 + alpha
        b0 = nb0 / a0; b1 = nb1 / a0; b2 = nb2 / a0
        a1 = (-2 * c) / a0; a2 = (1 - alpha) / a0
        z1 = 0; z2 = 0
    }

    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}
