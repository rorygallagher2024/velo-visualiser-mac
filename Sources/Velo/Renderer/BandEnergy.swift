import Foundation

/// Low / mid / high, smoothed, plus an envelope.
///
/// Generative scenes don't want a spectrum — they want a few numbers that mean
/// "there is bass" and "the hats are busy". Every one of them was folding the
/// bands down itself, which is four copies of a decision about where bass ends.
/// It lives here now, once.
///
/// Rates are per second rather than per frame, so the motion is identical at
/// 60 fps and at 240. That distinction is not academic: the engine used to
/// smooth per frame and visibly damped twice as hard on a 240 Hz display.
struct BandEnergy {

    private(set) var low: Float = 0
    private(set) var mid: Float = 0
    private(set) var high: Float = 0
    /// Snaps up and eases down — this is what makes a scene surge on a hit
    /// rather than breathe symmetrically through it.
    private(set) var envelope: Float = 0

    var smoothing: Float = 6
    var envelopeAttack: Float = 14
    var envelopeRelease: Float = 2.5

    /// 31 third-octave bands from 20 Hz: 0..<9 is sub through low-mid, 9..<21
    /// the midrange, 21..<31 the top two octaves.
    mutating func update(bands: [Float], dt: Float) {
        guard bands.count == AudioEngine.bandCount else { return }
        let rawLow = Self.mean(bands, 0, 9)
        let rawMid = Self.mean(bands, 9, 21)
        let rawHigh = Self.mean(bands, 21, 31)

        let k = min(smoothing * dt, 1)
        low += (rawLow - low) * k
        mid += (rawMid - mid) * k
        high += (rawHigh - high) * k

        let rawEnv = max(rawLow, max(rawMid, rawHigh))
        let rate = rawEnv > envelope ? envelopeAttack : envelopeRelease
        envelope += (rawEnv - envelope) * min(rate * dt, 1)
    }

    private static func mean(_ values: [Float], _ from: Int, _ to: Int) -> Float {
        var sum: Float = 0
        for i in from..<to { sum += values[i] }
        return sum / Float(to - from)
    }
}

extension VeloScene {
    /// GLSL's `mod` and Metal's `fmod` disagree on negative operands, and every
    /// polar scene here feeds them an angle that goes negative. Ported shaders
    /// need the GLSL one or the kaleidoscope seam lands in the wrong place.
    static var glslMod: String {
        """
        static inline float gmod(float a, float b) { return a - b * floor(a / b); }
        """
    }

    /// Rotation matrix matching GLSL's `mat2(c, -s, s, c)` column order exactly.
    static var rotation2D: String {
        """
        static inline float2x2 rot2(float a) {
            float c = cos(a), s = sin(a);
            return float2x2(float2(c, -s), float2(s, c));
        }
        """
    }
}
