import Foundation

/// "Prism Field" — Deep Field, split into four coloured populations.
///
/// Deep Field's stars are one population that changes colour with the bass.
/// This is four separate skies laid over each other, one per band, each with
/// its own hue and each appearing only while its own band is actually playing.
/// Low bass brings deep red, mid bass amber, the midrange teal, the top end a
/// cool white. A track with no low end simply has no red stars in it; vocals
/// alone light the teal and leave the rest of the sky empty.
///
/// The band split doubles as the depth axis: bass gets a coarse grid, so its
/// stars are larger, sparser and drift fastest, and the treble gets a fine one
/// far away. That is free parallax, and it also matches how the ear places
/// those sounds.
///
/// Each band learns its own floor before any of this, for the reason set out in
/// `DeepFieldScene`: `currentBands()` is dB-normalised, so silence still reads
/// around 0.3 and a fixed threshold would either fire constantly or never.
final class PrismFieldScene: VeloScene {

    let name = "Prism Field"

    /// Four bands over the 31 third-octave bands, which run 20 Hz to 20 kHz.
    /// Split musically rather than evenly: the two bass bands are narrow
    /// because that is where a track's weight actually moves.
    private static let ranges: [Range<Int>] = [
        0..<5,      // low bass    — sub and kick fundamental
        5..<10,     // mid bass    — bass line, low toms
        10..<21,    // mids        — vocals, guitars, snare body
        21..<31,    // treble      — hats, air, cymbals
    ]

    private static let floorUpPerSec: Float = 0.12
    private static let floorDownPerSec: Float = 0.7
    private static let floorFreeze: Float = 0.05
    private static let floorSeed: Float = 0.30
    private static let headroom: Float = 0.10
    private static let span: Float = 0.34

    /// Attack fast, release slower, so a hit reads as a hit rather than a swell.
    private static let attackPerSec: Float = 24
    private static let releasePerSec: Float = 5

    private var energy = BandEnergy()
    private var floors = [Float](repeating: floorSeed, count: 4)
    private var band = [Float](repeating: 0, count: 4)
    /// Accumulated, not derived from time: multiplying elapsed time by a rate
    /// that moves does not change speed, it jumps position.
    private var pan: Float = 0

    init() {
        energy.smoothing = 14
    }

    func update(audio: AudioEngine, dt: Float) {
        let bands = audio.currentBands()
        guard bands.count == AudioEngine.bandCount else { return }
        energy.update(bands: bands, dt: dt)

        let up = min(Self.floorUpPerSec * dt, 1)
        let down = min(Self.floorDownPerSec * dt, 1)

        for i in 0..<4 {
            let r = Self.ranges[i]
            var sum: Float = 0
            for b in r { sum += bands[b] }
            let raw = sum / Float(r.count)

            let signal = raw > floors[i] + Self.headroom
            let floorRate = signal ? up * Self.floorFreeze
                                   : (raw > floors[i] ? up : down)
            floors[i] += (raw - floors[i]) * floorRate

            let above = raw - floors[i] - Self.headroom
            let target = min(max(above / Self.span, 0), 1)
            let rate = target > band[i] ? Self.attackPerSec : Self.releasePerSec
            band[i] += (target - band[i]) * min(rate * dt, 1)
        }

        // Mids nudge the drift, integrated so the speed change stays a speed
        // change.
        pan += dt * 0.02 * (1 + band[2] * 0.6)
    }

    func writeData(into pointer: UnsafeMutableRawPointer) {
        let p = pointer.bindMemory(to: Float.self, capacity: 5)
        for i in 0..<4 { p[i] = band[i] }
        p[4] = pan
    }

    var shaderSource: String {
        """
        \(Self.shaderPreamble)

        struct Energy {
            float lowBass;
            float midBass;
            float mids;
            float treble;
            float pan;
        };

        \(Self.fullscreenVertexShader)

        // Warm at the bottom of the spectrum, cool at the top — the reading
        // most people already have for low and high sound.
        //
        // Program scope, not function scope: MSL rejects the `constant` address
        // space on an automatic variable, which is what stopped this scene
        // compiling at all.
        constant float3 RED   = float3(1.00, 0.26, 0.22);   // low bass
        constant float3 AMBER = float3(1.00, 0.62, 0.20);   // mid bass
        constant float3 TEAL  = float3(0.26, 0.86, 0.78);   // mids
        constant float3 ICE   = float3(0.80, 0.88, 1.00);   // treble

        static inline float hash21(float2 p) {
            float3 p3 = fract(float3(p.x, p.y, p.x) * 0.1031);
            p3 += dot(p3, p3.yzx + 33.33);
            return fract((p3.x + p3.y) * p3.z);
        }

        // One coloured population.
        //
        // The 3x3 sweep is required, not an optimisation choice: testing only
        // the fragment's own cell clips each star's falloff at the cell border
        // and leaves visible square edges. Nothing here scales or offsets the
        // grid by audio either — moving the grid slides stars between cells,
        // and a new cell is a new hash and therefore a different star, which
        // pops. `level` changes how a star looks, never where it is.
        static inline float3 population(float2 p, float scale, float seed,
                                        float fill, float level, float3 tint,
                                        float twinkleAmt, float time)
        {
            if (fill < 1e-4) return float3(0.0);

            float2 sp = p * scale;
            float2 baseId = floor(sp);
            float2 f = fract(sp);

            float cut = 1.0 - fill;
            float core = 0.00050 + level * 0.00110;

            float3 acc = float3(0.0);
            for (int y = -1; y <= 1; y++) {
                for (int x = -1; x <= 1; x++) {
                    float2 cell = float2(float(x), float(y));
                    float2 id = baseId + cell;
                    float rnd = hash21(id + seed);
                    if (rnd < cut) continue;

                    // Fade in as the threshold sweeps past rather than popping.
                    float fade = smoothstep(0.0, 0.35, saturate((rnd - cut) / fill));

                    float2 off = float2(hash21(id * 1.3 + seed) - 0.5,
                                        hash21(id * 2.7 + seed) - 0.5) * 0.6;
                    float2 sPos = cell + 0.5 + off;
                    float d2 = dot(f - sPos, f - sPos);

                    float b = core / (d2 + 0.00035);

                    float rate = 2.0 + rnd * 5.0;
                    float tw = 1.0 - twinkleAmt * (0.5 + 0.5 * sin(time * rate + rnd * 6.28318));

                    acc += tint * b * tw * fade;
                }
            }
            return acc;
        }

        fragment float4 veloFragment(VSOut in [[stage_in]],
                                     constant Uniforms &u [[buffer(0)]],
                                     constant Energy &e [[buffer(1)]])
        {
            float aspect = u.resolution.x / max(u.resolution.y, 1.0);
            float2 uv = float2(in.position.x, u.resolution.y - in.position.y)
                      / u.resolution;
            float2 p = (uv - 0.5) * float2(aspect, 1.0);
            float t = e.pan;

            float3 col = float3(0.0);

            // Coarse and near for bass, fine and far for treble. Densities are
            // deliberately low: four populations at Deep Field's density would
            // be four times the sky.
            col += population(p + float2(t * 1.90, t * 0.34), 62.0, 0.0,
                              e.lowBass * 0.020, e.lowBass, RED, 0.20, u.time);

            col += population(p + float2(t * 1.35, t * 0.24), 104.0, 137.0,
                              e.midBass * 0.024, e.midBass, AMBER, 0.28, u.time) * 0.85;

            col += population(p + float2(t * 0.85, t * 0.15), 168.0, 411.0,
                              e.mids * 0.028, e.mids, TEAL, 0.40, u.time) * 0.70;

            // The top end twinkles hardest, which is what hats sound like.
            col += population(p + float2(t * 0.45, t * 0.08), 280.0, 733.0,
                              e.treble * 0.032, e.treble, ICE, 0.75, u.time) * 0.55;

            // A modest overall lift from the whole spectrum, so a full mix has
            // more presence than any one band alone.
            float total = max(max(e.lowBass, e.midBass), max(e.mids, e.treble));
            col *= 0.45 + total * 1.35;

            col *= 1.0 - 0.55 * dot(p, p);

            // Roll off rather than clip, so a moment with every band lit does
            // not flatten to white and lose the colours entirely.
            col = col / (1.0 + col * 0.28);

            return float4(themeGrade(col, u) * u.dim, 1.0);
        }
        """
    }
}
