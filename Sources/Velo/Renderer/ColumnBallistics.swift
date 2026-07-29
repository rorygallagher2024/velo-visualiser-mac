import Foundation

/// Bar levels and gravity peak holds, for any scene drawn as columns.
///
/// Six scenes want the same motion: a bar that rises fast and falls slowly, and
/// a peak marker that is kicked up instantly, hovers, then falls away under
/// gravity. That was four copies of the same twenty lines, differing only in
/// their constants, which is four places for the physics to drift apart.
///
/// Rates are per second and applied exponentially, so the motion is identical
/// at 60 fps and at 240. A rate of 60 arrives in about 17 ms, which reads as
/// instant without being a discontinuity; `instantAttack` is the genuine step,
/// for LED panels, which have no mass to accelerate.
struct ColumnBallistics {

    private(set) var level: [Float]
    private(set) var peak: [Float]
    private var hold: [Float]
    private var velocity: [Float]

    var attackRate: Float = 60
    var releaseRate: Float = 12
    var instantAttack = false
    var peakHoldSec: Float = 0.6
    /// Scale-units per second squared.
    var peakGravity: Float = 1.6

    let count: Int

    init(count: Int) {
        self.count = count
        level = [Float](repeating: 0, count: count)
        peak = [Float](repeating: 0, count: count)
        hold = [Float](repeating: 0, count: count)
        velocity = [Float](repeating: 0, count: count)
    }

    /// Advance every column. Returns the loudest raw target, which is what an
    /// idle detector needs and what a smoothed level cannot tell it.
    @discardableResult
    mutating func update(targets: [Float], dt: Float) -> Float {
        guard targets.count == count else { return 0 }
        var loudest: Float = 0
        for i in 0..<count {
            let target = targets[i]
            loudest = max(loudest, target)

            if instantAttack, target >= level[i] {
                level[i] = target
            } else {
                let rate = target >= level[i] ? attackRate : releaseRate
                level[i] += (target - level[i]) * (1 - exp(-rate * dt))
            }

            if level[i] >= peak[i] {
                peak[i] = level[i]
                velocity[i] = 0
                hold[i] = peakHoldSec
            } else if hold[i] > 0 {
                hold[i] -= dt
            } else {
                velocity[i] += peakGravity * dt
                peak[i] = max(level[i], peak[i] - velocity[i] * dt)
            }
        }
        return loudest
    }

    /// Fold a finer spectrum down to this many columns, averaging each span.
    static func fold(_ source: [Float], into columns: Int) -> [Float] {
        guard !source.isEmpty else { return [Float](repeating: 0, count: columns) }
        var out = [Float](repeating: 0, count: columns)
        for i in 0..<columns {
            let lo = i * source.count / columns
            let hi = max((i + 1) * source.count / columns, lo + 1)
            var sum: Float = 0
            for j in lo..<hi { sum += source[min(j, source.count - 1)] }
            out[i] = sum / Float(hi - lo)
        }
        return out
    }

    /// Levels then peaks, contiguous, which is the layout every column shader
    /// here expects.
    func write(into pointer: UnsafeMutableRawPointer) {
        let bytes = count * MemoryLayout<Float>.stride
        level.withUnsafeBufferPointer { pointer.copyMemory(from: $0.baseAddress!, byteCount: bytes) }
        peak.withUnsafeBufferPointer {
            pointer.advanced(by: bytes).copyMemory(from: $0.baseAddress!, byteCount: bytes)
        }
    }
}
