import Foundation

/// "Chromatic Frame" — edge-strip variant of Chromatic Dots for DJ overlays.
///
/// The same five particle classes (bass, mid, high, loudness, beat) with the
/// same reactivity, but every dot is assigned to one of four screen edges
/// (top, bottom, left, right) and lives in a shallow strip along it. The
/// centre stays completely clear for camera or content. Bass pushes dots
/// outward past the edges; beat transients contract the frame inward.
final class ChromaticFrameScene: VeloScene {

    let name = "Chromatic Frame"

    private static let dots = 15000

    let draw = SceneDraw.points(ChromaticFrameScene.dots)

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

            int edge = int(vid) % 4;
            float localSeed = float(int(vid) / 4);

            float along = (hash11(localSeed * 0.1031 + float(edge) * 7.7) * 2.0 - 1.0) * 1.3;
            float rawDepth = hash11(localSeed * 0.3107 + float(edge) * 13.3);
            float depth = rawDepth * rawDepth * 0.35;

            float2 target;
            if (edge < 1)      { target = float2(along * aspect,          1.0 - depth); }
            else if (edge < 2) { target = float2(along * aspect,         -1.0 + depth); }
            else if (edge < 3) { target = float2(-aspect + depth * aspect, along); }
            else               { target = float2( aspect - depth * aspect, along); }

            float2 edgeNormal;
            if (edge < 1)      { edgeNormal = float2(0.0,     1.0); }
            else if (edge < 2) { edgeNormal = float2(0.0,    -1.0); }
            else if (edge < 3) { edgeNormal = float2(-aspect,  0.0); }
            else               { edgeNormal = float2( aspect,  0.0); }

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

            float2 pos = target + curl(target * 3.0 + u.time * speed) * 0.06 * (1.0 + energy);

            if (dotType < 0.5) {
                pos += edgeNormal * energy * 0.35;
            } else if (dotType > 3.5) {
                pos *= (1.0 - energy * 0.15);
            }

            pos.x /= aspect;

            float fade = 1.0 - smoothstep(0.02, 0.32, depth);

            out.position = float4(pos, 0.0, 1.0);
            out.size = max(baseSize * dpi * (0.5 + energy * 2.5) * fade, 0.0);
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
            col *= core * in.dotEnergy * 2.5;
            col = themeGrade(col, u) * u.dim;
            return float4(col, 1.0);
        }
        """
    }
}
