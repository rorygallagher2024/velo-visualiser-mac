import Foundation

/// "Chromatic Dots" — ported from Android.
///
/// Five classes of particle, one per musical element: bass (orange), mid
/// (green), high (blue), loudness (magenta) and beat (white). Each dot
/// disappears when its element is quiet and swells when it is loud, so the
/// field reads as a live breakdown of whatever is playing. Bass dots explode
/// outward from the centre; beat dots pull inward on the transient.
///
/// All positions and per-dot attributes are derived from `vertex_id` — the
/// Android original stores them in a static VBO, but the values are nothing
/// more than deterministic random draws, so hashing the index reproduces
/// them exactly.
final class ChromaticDotsScene: VeloScene {

    let name = "Chromatic Dots"

    private static let dots = 15000

    let draw = SceneDraw.points(ChromaticDotsScene.dots)

    private var energy = BandEnergy()
    private var smoothedBass: Float = 0
    private var smoothedMid: Float = 0
    private var smoothedHigh: Float = 0
    private var smoothedLoudness: Float = 0

    func update(audio: AudioEngine, dt: Float) {
        energy.update(bands: audio.currentBands(), dt: dt)
        let bass = max(energy.low - 0.15, 0) * 1.15
        let mid  = max(energy.mid - 0.15, 0) * 1.15
        let high = max(energy.high - 0.15, 0) * 1.15
        let loud = energy.envelope

        smoothedBass += (bass - smoothedBass) * 0.15
        smoothedMid  += (mid  - smoothedMid)  * 0.15
        smoothedHigh += (high - smoothedHigh) * 0.15
        smoothedLoudness += (loud - smoothedLoudness) * 0.15
    }

    func writeData(into pointer: UnsafeMutableRawPointer) {
        let p = pointer.bindMemory(to: Float.self, capacity: 5)
        p[0] = smoothedBass
        p[1] = smoothedMid
        p[2] = smoothedHigh
        p[3] = smoothedLoudness
        p[4] = energy.envelope
    }

    var shaderSource: String {
        """
        \(Self.shaderPreamble)

        struct DotsData {
            float bass;
            float mid;
            float high;
            float loudness;
            float beat;
        };

        constant uint DOTS = \(Self.dots);

        struct VSOut {
            float4 position [[position]];
            float  size     [[point_size]];
            float  dotType;
            float  dotEnergy;
        };

        static inline float hash11(float p) {
            p = fract(p * 0.1031);
            p *= p + 33.33;
            p *= p + p;
            return fract(p);
        }

        static inline float2 hash21(float p) {
            float3 p3 = fract(float3(p) * float3(0.1031, 0.1030, 0.0973));
            p3 += dot(p3, p3.yzx + 33.33);
            return fract(float2((p3.x + p3.y) * p3.z, (p3.x + p3.z) * p3.y));
        }

        static inline float vnoise(float2 p) {
            float2 i = floor(p), f = fract(p);
            float a = hash11(dot(i, float2(127.1, 311.7)));
            float b = hash11(dot(i + float2(1, 0), float2(127.1, 311.7)));
            float c = hash11(dot(i + float2(0, 1), float2(127.1, 311.7)));
            float d = hash11(dot(i + float2(1, 1), float2(127.1, 311.7)));
            float2 u = f * f * (3.0 - 2.0 * f);
            return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
        }

        static inline float2 curl(float2 p) {
            float e = 0.1;
            float nx1 = vnoise(p + float2(0.0, e)), nx2 = vnoise(p - float2(0.0, e));
            float ny1 = vnoise(p + float2(e, 0.0)), ny2 = vnoise(p - float2(e, 0.0));
            return float2(nx1 - nx2, -(ny1 - ny2)) / (2.0 * e);
        }

        vertex VSOut veloVertex(uint vid [[vertex_id]],
                                constant Uniforms &u [[buffer(0)]],
                                constant DotsData &s [[buffer(1)]])
        {
            float aspect = u.resolution.x / max(u.resolution.y, 1.0);
            float dpi = max(u.resolution.y / 1080.0, 1.0);

            float seed = hash11(float(vid) * 0.097);
            float2 r = hash21(float(vid) + 1.0);
            float2 target = (r * 2.0 - 1.0);
            target *= hash21(float(vid) * 1.618 + 7.0);

            float baseSize = 2.0 + hash11(float(vid) * 0.371) * 5.0;
            float dotType = float(vid % 5u);

            float energy = 0.0;
            float speed = 1.0;
            if (dotType < 0.5) { energy = s.bass; speed = 0.5; }
            else if (dotType < 1.5) { energy = s.mid; speed = 1.0; }
            else if (dotType < 2.5) { energy = s.high; speed = 2.0; }
            else if (dotType < 3.5) { energy = s.loudness; speed = 0.8; }
            else { energy = s.beat; speed = 3.0; }

            VSOut out;
            out.dotType = dotType;
            out.dotEnergy = energy;

            if (energy < 0.02) {
                out.position = float4(1e6, 1e6, 0.0, 1.0);
                out.size = 0.0;
                return out;
            }

            float2 pos = target + curl(target * 3.0 + u.time * speed) * 0.08 * (1.0 + energy);

            if (dotType < 0.5) {
                float2 dir = normalize(target + float2(1e-3));
                pos += dir * energy * 0.4;
            } else if (dotType > 3.5) {
                pos *= (1.0 - energy * 0.25);
            }

            pos.x /= aspect;
            out.position = float4(pos, 0.0, 1.0);
            out.size = max(baseSize * dpi * (0.5 + energy * 2.5), 1.0);
            return out;
        }

        fragment float4 veloFragment(VSOut in [[stage_in]],
                                     float2 pc [[point_coord]],
                                     constant Uniforms &u [[buffer(0)]])
        {
            float2 c = pc * 2.0 - 1.0;
            float d = dot(c, c);
            if (d > 1.0) { discard_fragment(); }
            float core = exp(-d * 4.0);

            float3 col;
            if (in.dotType < 0.5)      col = float3(1.0, 0.2, 0.0);
            else if (in.dotType < 1.5) col = float3(0.2, 1.0, 0.3);
            else if (in.dotType < 2.5) col = float3(0.0, 0.6, 1.0);
            else if (in.dotType < 3.5) col = float3(1.0, 0.0, 0.8);
            else                       col = float3(1.0, 1.0, 1.0);

            col *= (1.0 + in.dotEnergy * 0.6);
            col *= core * in.dotEnergy * 2.5 * u.dim;
            return float4(col, 1.0);
        }
        """
    }
}
