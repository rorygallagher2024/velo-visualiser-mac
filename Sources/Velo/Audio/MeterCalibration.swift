import Foundation

/// Shared scale and overload detection for the metering scenes, so they can
/// never disagree about what "hot" means.
///
/// The scale is fixed: -60 to 0 dBFS, every source, no auto-gain. A given
/// deflection always means the same signal level.
///
/// Ported from Android's `MeterCalibration`.
final class MeterCalibration {

    static let ceilDb: Float = 0
    static let floorDb: Float = -60
    static let recentFrames = 2048

    /// Overload lamp brightness, 0..1.
    private(set) var overLit: Float = 0

    /// Tracked room / noise level in dBFS. Drives `atRest` only.
    private(set) var roomDb: Float = floorDb

    private var overHold: Float = 0

    private let dialGamma: Float = 0.75
    private let restMarginDb: Float = 4
    private let noiseFallSec: Float = 0.6
    private let noiseRiseSec: Float = 25

    private let fullScale: Float = 0.999
    private let overRun = 3
    private let overHoldSec: Float = 0.18
    private let overAttackRate: Float = 40
    private let overFadeRate: Float = 9

    func update(db: Float, dt: Float) {
        if roomDb.isNaN { roomDb = db }
        let tau = db < roomDb ? noiseFallSec : noiseRiseSec
        roomDb += (db - roomDb) * min(dt / tau, 1)
    }

    func position(_ db: Float) -> Float {
        let linear = (db - Self.floorDb) / (Self.ceilDb - Self.floorDb)
        return powf(min(max(linear, 0), 1), dialGamma)
    }

    func atRest(_ db: Float) -> Bool {
        db <= roomDb + restMarginDb
    }

    func updateOverload(pcm: UnsafeBufferPointer<Float>, dt: Float) {
        overHold = hasOverload(pcm) ? overHoldSec : max(0, overHold - dt)
        let target: Float = overHold > 0 ? 1 : 0
        let rate = target > overLit ? overAttackRate : overFadeRate
        overLit += (target - overLit) * min(rate * dt, 1)
    }

    func reset() {
        roomDb = .nan
        overHold = 0
        overLit = 0
    }

    private func hasOverload(_ pcm: UnsafeBufferPointer<Float>) -> Bool {
        let n = pcm.count
        let start = max(0, n - Self.recentFrames)
        var run = 0
        for i in start..<n {
            let s = pcm[i]
            if s >= fullScale || s <= -fullScale {
                run += 1
                if run >= overRun { return true }
            } else {
                run = 0
            }
        }
        return false
    }
}
