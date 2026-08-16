import Foundation

/// "Motes" — out-of-focus specks drifting in front of the lens.
///
/// The third thing a camera already does that an overlay can borrow: dust and
/// haze caught in a beam, rendered as bokeh because it is far outside the focal
/// plane. Soft discs with a bright rim, not points — a defocused highlight has
/// a flat centre and a ring, which is what makes it read as out of focus rather
/// than merely blurred.
///
/// Motes rise slowly and are pushed sideways by a drift, so the field always
/// moves even in near-silence. What audio changes is how many are lit and how
/// large they bloom, never where the grid sits: moving the sampling grid slides
/// a mote from one cell to the next, and a new cell means a new hash and so a
/// different mote, which pops.
///
/// The 3x3 sweep is required rather than an optimisation. A mote is wide, and
/// testing only the cell a fragment lands in clips its disc at the cell border
/// and leaves visible squares.
final class MotesScene: VeloScene {

    let name = "Motes"

    private var gate = BandGate()
    private var rise: Float = 0
    private var sway: Float = 0

    func update(audio: AudioEngine, dt: Float) {
        gate.update(bands: audio.currentBands(), dt: dt)
        // Integrated rather than derived from time, so the speed can vary
        // without the field jumping.
        rise += dt * (0.012 + gate.level[0] * 0.030)
        sway += dt * 0.020
    }

    func writeData(into pointer: UnsafeMutableRawPointer) {
        let p = pointer.bindMemory(to: Float.self, capacity: 7)
        for i in 0..<4 { p[i] = gate.level[i] }
        p[4] = gate.presence
        p[5] = rise
        p[6] = sway
    }

    var shaderSource: String {
        """
        \(Self.shaderPreamble)

        struct Motes {
            float lowBass;
            float midBass;
            float mids;
            float treble;
            float presence;
            float rise;
            float sway;
        };

        \(Self.fullscreenVertexShader)

        static inline float hash21(float2 p) {
            float3 p3 = fract(float3(p.x, p.y, p.x) * 0.1031);
            p3 += dot(p3, p3.yzx + 33.33);
            return fract((p3.x + p3.y) * p3.z);
        }

        // A defocused highlight: near-flat centre, brighter rim, soft edge.
        // A plain gaussian reads as a blurred dot; the rim is what says "out of
        // focus" to the eye.
        static inline float bokeh(float d, float r) {
            float disc = smoothstep(r, r * 0.55, d);
            float rim  = smoothstep(r, r * 0.86, d) - smoothstep(r * 0.86, r * 0.62, d);
            return disc * 0.55 + max(rim, 0.0) * 0.9;
        }

        static inline float3 layer(float2 p, float scale, float seed,
                                   float fill, float size, float3 tint,
                                   float rise, float sway, float time)
        {
            if (fill < 1e-4) return float3(0.0);

            // Motion is applied to the SAMPLE POSITION only. The grid itself
            // never scales with audio.
            float2 sp = (p + float2(sin(sway + seed) * 0.05, -rise)) * scale;
            float2 baseId = floor(sp);
            float2 f = fract(sp);

            float cut = 1.0 - fill;
            float3 acc = float3(0.0);

            for (int y = -1; y <= 1; y++) {
                for (int x = -1; x <= 1; x++) {
                    float2 cell = float2(float(x), float(y));
                    float2 id = baseId + cell;
                    float rnd = hash21(id + seed);
                    if (rnd < cut) continue;

                    float fade = smoothstep(0.0, 0.35, saturate((rnd - cut) / fill));

                    float2 off = float2(hash21(id * 1.7 + seed) - 0.5,
                                        hash21(id * 3.1 + seed) - 0.5) * 0.55;
                    float2 c = cell + 0.5 + off;
                    float d = length(f - c);

                    // Varied sizes, so it reads as depth rather than a pattern.
                    float r = size * (0.55 + hash21(id * 5.3 + seed) * 0.85);
                    float shape = bokeh(d, r);
                    if (shape <= 0.0) continue;

                    // Slow independent breathing, so the field is never static.
                    float br = 0.65 + 0.35 * sin(time * (0.3 + rnd * 0.5) + rnd * 6.28318);

                    acc += tint * shape * br * fade;
                }
            }
            return acc;
        }

        constant float3 T_WARM = float3(1.00, 0.80, 0.58);
        constant float3 T_COOL = float3(0.62, 0.80, 1.00);

        fragment float4 veloFragment(VSOut in [[stage_in]],
                                     constant Uniforms &u [[buffer(0)]],
                                     constant Motes &s [[buffer(1)]])
        {
            float aspect = u.resolution.x / max(u.resolution.y, 1.0);
            float2 uv = float2(in.position.x, u.resolution.y - in.position.y)
                      / u.resolution;
            float2 p = (uv - 0.5) * float2(aspect, 1.0);

            float bass = max(s.lowBass, s.midBass);

            // Near motes: few, large, warm, and the ones the bass swells.
            float3 col = layer(p, 5.5, 0.0,
                               s.presence * 0.30, 0.16 + bass * 0.10,
                               T_WARM, s.rise * 1.6, s.sway, u.time) * 0.55;

            // Mid motes.
            col += layer(p, 10.0, 137.0,
                         s.presence * 0.26, 0.11 + bass * 0.05,
                         mix(T_WARM, T_COOL, 0.5), s.rise, s.sway * 1.3, u.time) * 0.45;

            // Far motes: more of them, small, cool, lifted by the top end.
            col += layer(p, 18.0, 411.0,
                         s.presence * 0.22, 0.08,
                         T_COOL, s.rise * 0.6, s.sway * 0.7, u.time)
                 * (0.30 + s.treble * 0.35);

            col *= 0.30 + s.presence * 1.10;

            col *= 1.0 - 0.35 * dot(p, p);

            // Roll off rather than clip, so overlapping discs keep their shape.
            col = col / (1.0 + col * 0.5);

            return float4(themeGrade(col, u) * u.dim, 1.0);
        }
        """
    }
}
