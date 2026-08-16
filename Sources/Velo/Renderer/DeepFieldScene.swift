import Foundation

/// "Deep Field" — Nebula's starfield, without the nebula.
///
/// Nebula's volumetric haze reads as noise over a video feed, but its starfield
/// works. This keeps the stars and throws the haze away, then makes the stars
/// carry the track instead of merely sparkling on top of it.
///
/// Three things were wrong with them as inherited:
///
/// **They were always there.** Density was a fixed `rnd > 0.94` — 6% of cells,
/// regardless of audio — and brightness carried a `0.4` floor, so a silent room
/// still showed a full sky. Density and brightness now both scale from nothing.
///
/// **They only heard the top end.** Brightness was `0.4 + hi * 1.5` and nothing
/// else. Bass had no effect at all, which is the opposite of what a track
/// dropping out should look like.
///
/// **Silence does not read as zero.** `BandEnergy` is built from the same
/// dB-normalised scale as the spectrum — -88 dBFS maps to 0 and -12 dBFS to 1 —
/// so a quiet room still sits around 0.3 and any fixed threshold either fires
/// constantly or never. Each band therefore learns its own floor and is
/// expressed as how far it rises above it, which is what makes "no music, no
/// stars" actually hold.
final class DeepFieldScene: VeloScene {

    let name = "Deep Field"

    private var energy = BandEnergy()

    // Attack fast, release slower. A symmetric follower makes a beat read as a
    // fade in and out, because it takes as long to rise as to fall; the snap is
    // what makes it read as a hit. Per second, so it is the same at any frame
    // rate.
    private static let attackPerSec: Float = 24
    private static let releasePerSec: Float = 5
    private static let presenceAttackPerSec: Float = 16
    private static let presenceReleasePerSec: Float = 2.5

    init() {
        // Default is 6, which is a ~170 ms slew — most of a kick's transient is
        // gone by the time it arrives. This scene wants the edge.
        energy.smoothing = 14
    }

    // Per-band noise floor. Same shape that settled Topographic Ridge: both
    // directions slow, so the estimate sits at the typical quiet level rather
    // than chasing the lowest dip, and nearly frozen while a band is clearly
    // above its floor so sustained music never teaches it its own level.
    private static let floorUpPerSec: Float = 0.12
    private static let floorDownPerSec: Float = 0.7
    private static let floorFreeze: Float = 0.05
    private static let floorSeed: Float = 0.30
    private static let headroom: Float = 0.10
    /// Range above floor+headroom that counts as "full", in band units.
    private static let span: Float = 0.34

    private var floors: [Float] = [floorSeed, floorSeed, floorSeed]
    /// Low / mid / high, each 0...1 above its own floor.
    private var band: [Float] = [0, 0, 0]
    /// Overall presence, 0 when nothing is playing.
    private var presence: Float = 0

    /// Accumulated pan, integrated here rather than derived in the shader.
    ///
    /// The first version panned with `time * rate` where the rate itself moved
    /// with the mids. Multiplying elapsed time by a changing rate does not
    /// change the speed, it teleports the position — every change in the mids
    /// jumped the whole field. Integrating rate over dt is the only way to vary
    /// a speed continuously.
    private var pan: Float = 0

    func update(audio: AudioEngine, dt: Float) {
        energy.update(bands: audio.currentBands(), dt: dt)

        let raw = [energy.low, energy.mid, energy.high]
        let up = min(Self.floorUpPerSec * dt, 1)
        let down = min(Self.floorDownPerSec * dt, 1)

        for i in 0..<3 {
            let signal = raw[i] > floors[i] + Self.headroom
            let floorRate = signal ? up * Self.floorFreeze
                                   : (raw[i] > floors[i] ? up : down)
            floors[i] += (raw[i] - floors[i]) * floorRate

            let above = raw[i] - floors[i] - Self.headroom
            let target = min(max(above / Self.span, 0), 1)
            let bandRate = target > band[i] ? Self.attackPerSec : Self.releasePerSec
            band[i] += (target - band[i]) * min(bandRate * dt, 1)
        }

        // Presence follows the loudest band, and asymmetrically too, so the sky
        // arrives on the hit and decays after it rather than swelling into it.
        let target = max(band[0], max(band[1], band[2]))
        let pRate = target > presence
            ? Self.presenceAttackPerSec
            : Self.presenceReleasePerSec
        presence += (target - presence) * min(pRate * dt, 1)

        pan += dt * 0.02 * (1 + band[1] * 0.6)
    }

    func writeData(into pointer: UnsafeMutableRawPointer) {
        let p = pointer.bindMemory(to: Float.self, capacity: 5)
        p[0] = band[0]
        p[1] = band[1]
        p[2] = band[2]
        p[3] = presence
        p[4] = pan
    }

    var shaderSource: String {
        """
        \(Self.shaderPreamble)

        struct Energy {
            float low;
            float mid;
            float hi;
            float pres;
            float pan;    // integrated on the CPU, never derived from time here
        };

        \(Self.fullscreenVertexShader)

        static inline float hash21(float2 p) {
            float3 p3 = fract(float3(p.x, p.y, p.x) * 0.1031);
            p3 += dot(p3, p3.yzx + 33.33);
            return fract((p3.x + p3.y) * p3.z);
        }

        // One parallax layer of stars.
        //
        // `fill` is the fraction of cells that hold a star, and it starts at
        // nothing: in silence the sky is genuinely empty rather than dimmed.
        //
        // The 3x3 sweep is not optional. Testing only the cell a fragment falls
        // in clips every star's glow at its cell border, which is what produced
        // the visible square cut-offs — a star sitting near an edge simply
        // stopped there. Neighbours have to be consulted so the falloff can
        // cross the boundary.
        //
        // Nothing here scales or offsets by audio. Moving the sampling grid
        // makes stars drift between cells, and a cell change means a different
        // hash and therefore a different star, which pops. Bass changes how a
        // star LOOKS — size, colour, brightness — never where the grid is.
        static inline float3 starLayer(float2 p, float scale, float seed,
                                       float fill, float bass, float hi,
                                       float time)
        {
            if (fill < 1e-4) return float3(0.0);

            float2 sp = p * scale;
            float2 baseId = floor(sp);
            float2 f = fract(sp);

            float cut = 1.0 - fill;
            // Small and tight. The first version used 0.0016 + bass * 0.0060
            // over a softer falloff, which at full bass made every star a fat
            // blob several cells wide.
            float core = 0.00060 + bass * 0.00120;

            float3 warm = float3(1.00, 0.86, 0.70);
            float3 cool = float3(0.72, 0.82, 1.00);
            float3 tint = mix(cool, warm, bass);

            float3 acc = float3(0.0);
            for (int y = -1; y <= 1; y++) {
                for (int x = -1; x <= 1; x++) {
                    float2 cell = float2(float(x), float(y));
                    float2 id = baseId + cell;
                    float rnd = hash21(id + seed);
                    if (rnd < cut) continue;

                    // Fade in as the threshold sweeps past, rather than popping
                    // on at full brightness.
                    float birth = saturate((rnd - cut) / fill);
                    float fade = smoothstep(0.0, 0.35, birth);

                    float2 off = float2(hash21(id * 1.3 + seed) - 0.5,
                                        hash21(id * 2.7 + seed) - 0.5) * 0.6;
                    // Star position relative to this fragment's own cell.
                    float2 sPos = cell + 0.5 + off;
                    float d2 = dot(f - sPos, f - sPos);

                    float brightness = core / (d2 + 0.00035);

                    float rate = 2.0 + rnd * 5.0;
                    float twinkle = 1.0 - hi * (0.5 + 0.5 * sin(time * rate + rnd * 6.28318));

                    acc += tint * brightness * twinkle * fade;
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

            float low  = e.low;
            float hi   = e.hi;
            float pres = e.pres;
            // Already integrated, so a change in speed stays a change in speed.
            float t    = e.pan;

            float3 col = float3(0.0);

            // Three layers at different scales and speeds. Finer grids than the
            // first attempt — a coarse grid means large cells, and a large cell
            // is a large star.
            col += starLayer(p + float2(t * 1.60, t * 0.30), 78.0, 0.0,
                             pres * 0.030, low, hi, u.time);
            col += starLayer(p + float2(t * 0.90, t * 0.15), 150.0, 137.0,
                             pres * 0.038, low, hi, u.time) * 0.75;
            col += starLayer(p + float2(t * 0.45, t * 0.08), 270.0, 411.0,
                             pres * 0.046, low, hi, u.time) * 0.50;

            // Overall level tracks presence too, so the fade to an empty sky is
            // in brightness as well as in count.
            col *= 0.35 + pres * 1.65;

            // A little extra lift on the low end, kept modest: this decorates a
            // stream and should not pump.
            col *= 1.0 + low * 0.5;

            // Vignette, matching Nebula's framing.
            col *= 1.0 - 0.55 * dot(p, p);

            // Gentle roll-off so a dense bass moment does not clip to white.
            col = col / (1.0 + col * 0.25);

            return float4(themeGrade(col, u) * u.dim, 1.0);
        }
        """
    }
}
