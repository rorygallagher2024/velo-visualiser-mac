import Foundation

/// Turns the analyser's bands into "how much of this is actually playing".
///
/// `AudioEngine.currentBands()` is dB-normalised — -88 dBFS maps to 0 and
/// -12 dBFS to 1 — so a silent room still reads around 0.3. Any scene that
/// compares a band against a fixed threshold therefore either fires constantly
/// or never fires, and a scene that multiplies by it is never truly dark. This
/// learns what each band reads when nothing is playing and reports how far it
/// rises above that, which is what makes silence read as zero.
///
/// Written once here because three scenes had grown their own copy.
///
/// Two behaviours worth knowing:
///
/// **The floor is nearly frozen while a band is loud.** Otherwise a sustained
/// passage teaches the floor its own level and slowly erases itself.
///
/// **The output follower is asymmetric.** A symmetric one makes a beat read as
/// a fade in and out, because it takes as long to rise as to fall.
struct BandGate {

    /// Band edges over the 31 third-octave bands, which run 20 Hz to 20 kHz.
    /// Split musically: the bass ranges are narrow because that is where a
    /// track's weight moves.
    static let fourWay: [Range<Int>] = [
        0..<5,      // low bass  — sub, kick fundamental      ~20-63 Hz
        5..<10,     // mid bass  — bass line, low toms        ~63-200 Hz
        10..<21,    // mids      — vocals, guitars, snare     ~200 Hz-2.5 kHz
        21..<31,    // treble    — hats, air, cymbals         ~2.5-20 kHz
    ]

    /// Per second, so behaviour is identical at 60 and 240 Hz.
    var floorUpPerSec: Float = 0.12
    var floorDownPerSec: Float = 0.7
    /// How much of the rise rate survives while a band is clearly above floor.
    var floorFreeze: Float = 0.05
    var headroom: Float = 0.10
    /// Range above floor+headroom that counts as full, in band units.
    var span: Float = 0.34
    var attackPerSec: Float = 24
    var releasePerSec: Float = 5

    /// 0...1 per range, above that range's own learned floor.
    private(set) var level: [Float]
    /// The loudest range, eased the same way.
    private(set) var presence: Float = 0

    private let ranges: [Range<Int>]
    private var floors: [Float]

    init(ranges: [Range<Int>] = BandGate.fourWay, floorSeed: Float = 0.30) {
        self.ranges = ranges
        self.floors = Array(repeating: floorSeed, count: ranges.count)
        self.level = Array(repeating: 0, count: ranges.count)
    }

    mutating func update(bands: [Float], dt: Float) {
        guard bands.count == AudioEngine.bandCount else { return }
        let up = min(floorUpPerSec * dt, 1)
        let down = min(floorDownPerSec * dt, 1)

        for i in ranges.indices {
            let r = ranges[i]
            var sum: Float = 0
            for b in r { sum += bands[b] }
            let raw = sum / Float(r.count)

            let loud = raw > floors[i] + headroom
            let floorRate = loud ? up * floorFreeze : (raw > floors[i] ? up : down)
            floors[i] += (raw - floors[i]) * floorRate

            let above = raw - floors[i] - headroom
            let target = min(max(above / span, 0), 1)
            let rate = target > level[i] ? attackPerSec : releasePerSec
            level[i] += (target - level[i]) * min(rate * dt, 1)
        }

        let loudest = level.max() ?? 0
        let rate = loudest > presence ? attackPerSec : releasePerSec
        presence += (loudest - presence) * min(rate * dt, 1)
    }
}
