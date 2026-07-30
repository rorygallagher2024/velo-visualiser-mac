import Foundation

/// Real-time 4/4 beat-grid tracker: turns the reactive onset stream into a
/// steady *predicted* grid so the visuals and lights pulse on the quarter notes
/// and ignore stray transients between them.
///
/// Two stages, deliberately separated:
///
///  - **Tempo** comes from *autocorrelation* of a continuous onset-novelty
///    envelope. The novelty is accumulated into fixed 10 ms bins (so timing is
///    independent of the jittery frame rate), and the buffer is correlated
///    against itself over the lags that correspond to a musical tempo range. A
///    gentle mid-tempo weighting breaks half/double ambiguity.
///  - **Phase** comes from a light phase-locked loop that nudges the predicted
///    grid toward onsets that land near it (the kicks).
///
/// Confidence is the normalised height of the autocorrelation peak: a strongly
/// periodic signal scores near 1, ambiguous or non-4/4 material scores low.
/// Below the lock threshold the caller falls back to the raw reactive detector.
///
/// Runs on the render thread each frame; single-threaded, no locking.
///
/// Ported from Android's `FourFourTracker.kt` — same algorithm, same constants.
final class FourFourTracker {

    struct Tick {
        let beat: Bool
        let envelope: Float
        let barPhase: Float
        let confident: Bool
        let bpm: Float
    }

    private let detector = SpectralOnsetDetector(sourceScaled: false)

    // Onset-novelty envelope in fixed 10 ms bins (a ring).
    private var env = [Float](repeating: 0, count: envLen)
    private var lin = [Float](repeating: 0, count: envLen)
    private var envHead = 0
    private var envCount = 0
    private var binAccum: Float = 0
    private var binEndSec: Double = 0

    private var periodSec: Double = 0
    private var nextBeatSec: Double = 0
    private var beatInBar = 0
    private var recalcAtSec: Double = 0
    private var lastEmittedBeatSec: Double = 0

    private var confidence: Float = 0
    private var confidentState = false
    private var lastBpm: Float = 0
    private var prefLag: Double = Double(prefLagDefault)
    private var scratchPeak: Float = 0
    private var acPeaks = [Float](repeating: 0, count: maxLag + 1)

    /// Call once per frame from the render thread.
    ///
    /// - Parameters:
    ///   - nowSec: monotonic time in seconds (e.g. `CACurrentMediaTime()`).
    ///   - spectrum: the latest 128-bin magnitude spectrum.
    ///   - gateOpen: whether audio presence is above the silence floor.
    ///   - time: monotonic time used by the spectral onset detector.
    func update(nowSec: Double, spectrum: [Float], gateOpen: Bool, time: Float) -> Tick {
        let _ = detector.update(spectrum: spectrum, time: time)
        accumulateEnvelope(nowSec: nowSec, novelty: gateOpen ? detector.lastNovelty : 0)

        if nowSec >= recalcAtSec {
            recalcAtSec = nowSec + Self.recalcSec
            recomputeTempo()
        }

        if periodSec <= 0 { return Tick(beat: false, envelope: 0, barPhase: 0, confident: false, bpm: 0) }

        if nextBeatSec <= 0 { nextBeatSec = nowSec + periodSec }
        if detector.lastNovelty > 0.3 && gateOpen { alignToOnset(nowSec: nowSec) }

        let beat = advanceGrid(nowSec: nowSec)

        let within = min(max(1.0 - (nextBeatSec - nowSec) / periodSec, 0), 1)
        let envelope = Float((1.0 - within) * (1.0 - within))
        let barPhase = min(Float((Double(beatInBar) + within) / 4.0), 1)

        return Tick(beat: beat, envelope: envelope, barPhase: barPhase,
                    confident: confidentState, bpm: lastBpm)
    }

    func reset() {
        envHead = 0; envCount = 0; binAccum = 0; binEndSec = 0
        periodSec = 0; nextBeatSec = 0; beatInBar = 0; recalcAtSec = 0
        lastEmittedBeatSec = 0
        confidence = 0; confidentState = false; lastBpm = 0
        prefLag = Double(Self.prefLagDefault)
    }

    // MARK: - Novelty envelope (fixed 10 ms bins)

    private func accumulateEnvelope(nowSec: Double, novelty: Float) {
        if binEndSec <= 0 { binEndSec = nowSec + Self.binSec; binAccum = novelty; return }
        if nowSec - binEndSec > Double(Self.envLen) * Self.binSec {
            envHead = 0; envCount = 0; binAccum = 0; binEndSec = nowSec + Self.binSec
            return
        }
        binAccum += novelty
        while nowSec >= binEndSec {
            pushBin(binAccum)
            binAccum = 0
            binEndSec += Self.binSec
        }
    }

    private func pushBin(_ v: Float) {
        env[envHead] = v
        envHead = (envHead + 1) % Self.envLen
        if envCount < Self.envLen { envCount += 1 }
    }

    // MARK: - Tempo via autocorrelation

    private func recomputeTempo() {
        if envCount < Self.minEnv { return }
        let totalE = unpackEnvelope()
        if totalE < 1e-6 { updateConfidence(peak: 0); return }
        let bestLag = bestTempoLag(totalE: totalE)
        if bestLag < 0 { updateConfidence(peak: 0); return }
        updatePeriod(candidate: refineLag(bestLag) * Self.binSec)
        updateConfidence(peak: scratchPeak)

        if confidentState && periodSec > 0 {
            let currentLag = periodSec / Self.binSec
            prefLag += Self.prefLagTrack * (currentLag - prefLag)
        } else {
            prefLag += Self.prefLagTrack * (Double(Self.prefLagDefault) - prefLag)
        }
    }

    private func unpackEnvelope() -> Float {
        let start = (envHead - envCount + Self.envLen) % Self.envLen
        var totalE: Float = 0
        for i in 0..<envCount {
            let v = env[(start + i) % Self.envLen]
            lin[i] = v
            totalE += v * v
        }
        return totalE
    }

    private func bestTempoLag(totalE: Float) -> Int {
        var bestLag = -1
        var bestScore: Float = 0
        var bestPeak: Float = 0
        for lag in Self.minLag...Self.maxLag {
            var cross: Float = 0
            var e1: Float = 0
            var e2: Float = 0
            for i in lag..<envCount {
                let a = lin[i]
                let b = lin[i - lag]
                cross += a * b
                e1 += a * a
                e2 += b * b
            }
            let peak = (e1 > 0 && e2 > 0) ? cross / sqrtf(e1 * e2) : 0
            acPeaks[lag] = peak
            let score = peak * tempoWeight(lag: lag)
            if score > bestScore { bestScore = score; bestLag = lag; bestPeak = peak }
        }
        scratchPeak = bestPeak
        return bestLag
    }

    private func refineLag(_ lag: Int) -> Double {
        if lag <= Self.minLag || lag >= Self.maxLag { return Double(lag) }
        let y1 = acPeaks[lag - 1]
        let y2 = acPeaks[lag]
        let y3 = acPeaks[lag + 1]
        let denom = y1 - 2 * y2 + y3
        if abs(denom) < 1e-6 { return Double(lag) }
        let delta = min(max(0.5 * (y1 - y3) / denom, -0.5), 0.5)
        return Double(lag) + Double(delta)
    }

    private func updatePeriod(candidate: Double) {
        if periodSec <= 0 {
            periodSec = candidate
        } else if abs(periodSec - candidate) > periodSec * Self.reseedFrac {
            periodSec = candidate
        } else {
            periodSec += Self.periodTrack * (candidate - periodSec)
        }
        lastBpm = Float(60.0 / periodSec)
    }

    private func updateConfidence(peak: Float) {
        confidence += Self.confTrack * (peak - confidence)
        if !confidentState && confidence >= Self.confHi { confidentState = true }
        else if confidentState && confidence < Self.confLo { confidentState = false }
    }

    private func tempoWeight(lag: Int) -> Float {
        let z = log(Double(lag) / prefLag) / Self.weightSigma
        return Float(exp(-0.5 * z * z))
    }

    // MARK: - Phase-locked loop

    private func alignToOnset(nowSec: Double) {
        let prevBeat = nextBeatSec - periodSec
        let err: Double
        if abs(nowSec - prevBeat) < abs(nowSec - nextBeatSec) {
            err = nowSec - prevBeat
        } else {
            err = nowSec - nextBeatSec
        }
        if abs(err) <= periodSec * Self.alignTol {
            nextBeatSec += Self.phaseCorrect * err
        }
    }

    private func advanceGrid(nowSec: Double) -> Bool {
        var beat = false
        var catchup = 0
        while nowSec >= nextBeatSec && catchup < Self.maxCatchup {
            if nextBeatSec - lastEmittedBeatSec > periodSec * 0.5 {
                beat = true
                lastEmittedBeatSec = nextBeatSec
                beatInBar = (beatInBar + 1) & 3
            }
            nextBeatSec += periodSec
            catchup += 1
        }
        if catchup >= Self.maxCatchup { nextBeatSec = nowSec + periodSec }
        return beat
    }

    // MARK: - Constants

    private static let binSec: Double = 0.01
    private static let envLen = 512
    private static let minEnv = 200

    private static let minLag = 34
    private static let maxLag = 71
    private static let prefLagDefault = 50
    private static let weightSigma: Double = 0.45
    private static let prefLagTrack: Double = 0.05

    private static let recalcSec: Double = 0.20
    private static let reseedFrac: Double = 0.20
    private static let periodTrack: Double = 0.30

    private static let alignTol: Double = 0.18
    private static let phaseCorrect: Double = 0.12
    private static let maxCatchup = 4

    private static let confTrack: Float = 0.25
    private static let confHi: Float = 0.34
    private static let confLo: Float = 0.22
}
