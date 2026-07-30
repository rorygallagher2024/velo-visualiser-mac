import Foundation
import QuartzCore

/// Single source of truth for the gated beat, shared by visuals, lighting, and
/// any other consumer that needs to react to the music.
///
/// The producer is the render thread (via `Renderer`), which each frame
/// measures audio presence, runs the `BeatDetector`, and publishes here.
/// Consumers read from their own threads — single writer, many readers, so
/// atomics or volatile reads are sufficient.
///
/// The rule: a beat only "counts" when there is enough audio present.
/// `loudness` expresses that gate as a 0..1 intensity, so consumers can scale
/// brightness/punch smoothly instead of hard-switching.
final class BeatBus: @unchecked Sendable {

    /// The production instance. Lighting and other off-render-thread consumers
    /// read this. Scenes should use `current` instead (set by the renderer).
    static let shared = BeatBus()

    /// The beat bus for the current render pass. Set by the renderer before
    /// updating scenes, so each scene reads the correct bus regardless of
    /// whether the renderer uses `.shared` or a local instance (self-test).
    nonisolated(unsafe) static var current: BeatBus = shared

    /// Global beat sensitivity. Set from the UI; read each frame by the
    /// detector and the audio-presence gate.
    nonisolated(unsafe) static var sensitivity: BeatSensitivity = .standard

    // ---- Written by the renderer each frame ----

    /// Beat-punch envelope: snaps to `loudness` on a beat, decays toward 0.
    private(set) var envelope: Float = 0

    /// Monotonic counter incremented once per gated beat.
    private(set) var beatCount: Int = 0

    /// Smoothed absolute audio level (peak-hold + decay).
    private(set) var level: Float = 0

    /// Volume-independent bass fraction 0..1.
    private(set) var bassRatio: Float = 0.5

    /// Gate intensity: smoothstep of level between base and full thresholds.
    /// 0 = below the floor (silent), 1 = fully present.
    private(set) var loudness: Float = 0

    /// True while there is enough audio present for a beat to count.
    var gateOpen: Bool { loudness > 0 }

    /// Bar phase (0..1) from Link or 4/4 tracker. 0 when neither is active.
    private(set) var barPhase: Float = 0

    // ---- Internal state, driven by update() ----

    private let detector = BeatDetector()
    private let fourFour = FourFourTracker()
    private var wasFourFour = false
    private var wasLink = false
    private var levelFollow: Float = 0
    private var bassLp: Float = 0
    private var bassRatioSmooth: Float = 0.5

    private let bassLpAlpha: Float = 0.025
    private let levelDecay: Float = 0.992
    private let micNoiseFloor: Float = 0.0015

    private let levelBaseRef: Float = 0.024 * 0.4
    private let levelFullRef: Float = 0.024

    private let punchFall: Float = 4.0

    // Link anticipation constants (matching Android)
    private let anticStart: Float = 0.70
    private let anticAmount: Float = 0.45

    init() {}

    func update(audio: AudioEngine, dt: Float, time: Float) {
        let pcmCount = 1024
        var pcm = [Float](repeating: 0, count: pcmCount)
        pcm.withUnsafeMutableBufferPointer { buf in
            audio.fillWaveform(buf.baseAddress!, count: pcmCount)
        }

        // Measure audio presence: absolute peak (loudness) and bass/treble
        // balance (colour for lighting).
        var peak: Float = 0
        var lp = bassLp
        var bassAcc: Float = 0
        var trebAcc: Float = 0
        for s in pcm {
            let a = abs(s)
            if a > peak { peak = a }
            lp += bassLpAlpha * (s - lp)
            bassAcc += lp * lp
            let tre = s - lp
            trebAcc += tre * tre
        }
        bassLp = lp

        let inv = 1.0 / Float(pcmCount)
        let bassRms = sqrtf(bassAcc * inv)
        let trebRms = sqrtf(trebAcc * inv)

        levelFollow = peak > levelFollow ? peak : levelFollow * levelDecay
        level = levelFollow

        let rawRatio = peak < micNoiseFloor ? 0 : bassRms / (bassRms + trebRms + 1e-6)
        bassRatioSmooth += 0.25 * (rawRatio - bassRatioSmooth)
        bassRatio = bassRatioSmooth

        // Apply sensitivity scaling each frame.
        let sens = Self.sensitivity.scale
        detector.thresholdScale = sens
        let levelBase = levelBaseRef * sens
        let levelFull = levelFullRef * sens

        // Gate: smoothstep(base, full, level) -> 0..1 intensity.
        let g = min(max((levelFollow - levelBase) / (levelFull - levelBase + 1e-6), 0), 1)
        loudness = g * g * (3 - 2 * g)

        // Beat decision. Source priority: Link > 4/4 Music Mode > reactive.
        // Link and 4/4 are mutually exclusive (Link takes precedence).
        var barPhaseNow: Float = 0

        if LinkSync.enabled {
            let rawBeat = LinkSession.pollBeats() > 0
            barPhaseNow = min(max(LinkSession.barPhase(), 0), 1)

            if LinkSync.barOffsetBeats != 0 {
                barPhaseNow = (barPhaseNow + Float(LinkSync.barOffsetBeats) * 0.25).truncatingRemainder(dividingBy: 1)
            }

            let phase = min(max(LinkSession.beatPhase(), 0), 1)
            let decay = (1 - phase) * (1 - phase)
            let env: Float
            if !LinkSync.anticipateBeat {
                env = decay
            } else {
                let a = min(max((phase - anticStart) / (1 - anticStart), 0), 1)
                let antic = a * a * (3 - 2 * a) * anticAmount
                env = antic > decay ? antic : decay
            }
            envelope = env * loudness

            if rawBeat && gateOpen {
                beatCount &+= 1
            }

            LinkSync.statusBpm = LinkSession.tempo()
            LinkSync.statusPeers = LinkSession.numPeers()

            wasLink = true
        } else if FourFourSync.enabled {
            if !wasFourFour { fourFour.reset() }

            let reactiveBeat = pcm.withUnsafeBufferPointer { buf in
                detector.update(pcm: buf, time: time)
            }

            let spectrum = audio.currentBins()
            let nowSec = CACurrentMediaTime()
            let tick = fourFour.update(nowSec: nowSec, spectrum: spectrum,
                                       gateOpen: gateOpen, time: time)
            FourFourSync.statusBpm = tick.confident ? tick.bpm : 0

            if tick.confident {
                barPhaseNow = tick.barPhase
                envelope = tick.envelope * loudness
                if tick.beat && gateOpen { beatCount &+= 1 }
            } else {
                if reactiveBeat && gateOpen {
                    envelope = loudness
                    beatCount &+= 1
                } else {
                    envelope = max(envelope - dt * punchFall, 0)
                }
            }

            wasLink = false
        } else {
            let beat = pcm.withUnsafeBufferPointer { buf in
                detector.update(pcm: buf, time: time)
            } && gateOpen

            if beat {
                envelope = loudness
                beatCount &+= 1
            } else {
                envelope = max(envelope - dt * punchFall, 0)
            }

            wasLink = false
        }

        wasFourFour = FourFourSync.enabled && !LinkSync.enabled
        barPhase = barPhaseNow
    }
}
