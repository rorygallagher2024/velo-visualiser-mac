import Foundation

/// Multi-band, self-calibrating spectral-flux onset detector, used only by
/// ``FourFourTracker``. The reactive path (visuals, lights) keeps the simpler
/// bass-RMS ``BeatDetector``, so toggling 4/4 mode off restores the original
/// behaviour; all experimental onset work lives here, behind that opt-in.
///
/// Onsets are a rise in the magnitude spectrum, measured as half-wave-rectified
/// spectral flux over the 128-bin spectrum the app already computes. The flux
/// is split into three bands, each calibrated to its own statistics:
///   - low  = the kick (~50-200 Hz),
///   - mid  = snares, claps, body,
///   - high = hats and air.
///
/// Per band, a slow follower tracks the noise floor and a fast one the onset
/// level; the band's detection value is its flux as a fraction of that local
/// dynamic range. Because each band self-normalises, a bare four-to-the-floor
/// kick drives the low band while a kick-less clap break drives the mid band.
///
/// Ported from Android's `SpectralOnsetDetector.kt` — same algorithm, same
/// constants.
final class SpectralOnsetDetector {

    private let minGapSeconds: Float
    private let sourceScaled: Bool

    private var prev: [Float]?
    private var b1 = 0
    private var b2 = 0
    private var bandFlux = [Float](repeating: 0, count: bands)
    private var noiseFloor = [Float](repeating: 0, count: bands)
    private var fluxPeak = [Float](repeating: 0, count: bands)
    private var lastBeatTime: Float = -.greatestFiniteMagnitude

    /// Onset strength this frame: kick-favouring combination of the per-band
    /// normalised fluxes. A continuous, scale-invariant novelty for the tracker.
    private(set) var lastNovelty: Float = 0

    init(minGapSeconds: Float = 0.12, sourceScaled: Bool = false) {
        self.minGapSeconds = minGapSeconds
        self.sourceScaled = sourceScaled
    }

    /// Feed the latest magnitude spectrum every frame; true on a detected onset.
    func update(spectrum: [Float], time: Float) -> Bool {
        guard let p = prev, p.count == spectrum.count else {
            prev = spectrum
            b1 = Int(Float(spectrum.count) * band1Frac)
            b2 = Int(Float(spectrum.count) * band2Frac)
            return false
        }

        computeBandFlux(spectrum: spectrum, prevSpectrum: p)
        prev = spectrum
        let novelty = combineNovelty(binCount: spectrum.count)
        lastNovelty = novelty

        let isBeat = novelty > combinedThreshold
            && (time - lastBeatTime) > minGapSeconds
        if isBeat { lastBeatTime = time }
        return isBeat
    }

    private func computeBandFlux(spectrum: [Float], prevSpectrum: [Float]) {
        bandFlux[0] = 0; bandFlux[1] = 0; bandFlux[2] = 0
        for i in spectrum.indices {
            let d = spectrum[i] - prevSpectrum[i]
            if d > 0 {
                let band = i < b1 ? 0 : (i < b2 ? 1 : 2)
                bandFlux[band] += d
            }
        }
    }

    private func combineNovelty(binCount: Int) -> Float {
        var combined: Float = 0
        for b in 0..<Self.bands {
            let width: Int
            switch b {
            case 0: width = b1
            case 1: width = b2 - b1
            default: width = binCount - b2
            }
            let f = width > 0 ? bandFlux[b] / Float(width) : 0

            noiseFloor[b] += (f - noiseFloor[b]) * (f > noiseFloor[b] ? noiseUp : noiseDown)
            fluxPeak[b] += (f - fluxPeak[b]) * (f > fluxPeak[b] ? peakUp : peakDown)

            let dyn = fluxPeak[b] - noiseFloor[b]
            let norm: Float
            if dyn > minDynamic {
                norm = min(max((f - noiseFloor[b]) / dyn, 0), 2)
            } else {
                norm = 0
            }
            combined += Self.bandWeight[b] * norm
        }
        return combined
    }

    // MARK: - Constants

    private static let bands = 3
    private let band1Frac: Float = 0.22
    private let band2Frac: Float = 0.55
    private static let bandWeight: [Float] = [1.0, 0.85, 0.5]

    private let noiseUp: Float = 0.010
    private let noiseDown: Float = 0.080
    private let peakUp: Float = 0.400
    private let peakDown: Float = 0.020
    private let minDynamic: Float = 0.002
    private let combinedThreshold: Float = 0.50
}
