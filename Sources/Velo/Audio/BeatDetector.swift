import Foundation

/// Bass-onset beat detector — the reactive path for visuals, lights, and any
/// future haptics.
///
/// Detects the *attack* of bass hits (the kick), not the bass *level*. Each
/// frame: one-pole low-pass the raw PCM to isolate the bass band, take its RMS,
/// then the positive flux (rise vs the previous frame).
///
/// The threshold is **self-calibrating**: two followers track the flux's own
/// noise floor (slow) and onset level (fast), and a beat fires when the flux
/// clears a fraction of that local dynamic range. A quiet laptop mic and a hot
/// interface both land in the same range without device-specific constants.
///
/// Ported from the Android `BeatDetector.kt` — same algorithm, same constants.
final class BeatDetector {

    private let lpAlpha: Float
    private let minGapSeconds: Float

    private var prevBass: Float = 0
    private var noiseFloor: Float = 0
    private var fluxPeak: Float = 0
    private var lastBeatTime: Float = -.greatestFiniteMagnitude

    init(lpAlpha: Float = 0.025, minGapSeconds: Float = 0.12) {
        self.lpAlpha = lpAlpha
        self.minGapSeconds = minGapSeconds
    }

    /// Feed the latest PCM window; returns true on a detected beat.
    func update(pcm: UnsafeBufferPointer<Float>, time: Float) -> Bool {
        var lp: Float = 0
        var sumSq: Float = 0
        for i in 0..<pcm.count {
            lp += lpAlpha * (pcm[i] - lp)
            sumSq += lp * lp
        }
        let bass = sqrtf(sumSq / Float(max(pcm.count, 1)))

        let flux = max(0, bass - prevBass)
        prevBass = bass

        noiseFloor += (flux - noiseFloor) * (flux > noiseFloor ? noiseUp : noiseDown)
        fluxPeak += (flux - fluxPeak) * (flux > fluxPeak ? peakUp : peakDown)

        let dynamic = fluxPeak - noiseFloor
        let norm: Float
        if dynamic > minDynamic {
            norm = min(max((flux - noiseFloor) / dynamic, 0), 2)
        } else {
            norm = 0
        }

        let isBeat = norm > normThreshold * thresholdScale
            && dynamic > minDynamic
            && (time - lastBeatTime) > minGapSeconds

        if isBeat { lastBeatTime = time }
        return isBeat
    }

    var thresholdScale: Float = 1.0

    private let noiseUp: Float = 0.010
    private let noiseDown: Float = 0.080
    private let peakUp: Float = 0.400
    private let peakDown: Float = 0.020
    private let minDynamic: Float = 0.003
    private let normThreshold: Float = 0.35
}
