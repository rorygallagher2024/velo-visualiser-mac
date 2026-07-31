import Foundation

/// "Corner Bloom" — four phyllotaxis spirals radiating from the screen corners.
///
/// Designed as an overlay visual for DJ sets: the same golden-angle spectrum
/// bloom as Phyllotaxis Bloom, but placed at each corner with a smooth fade
/// toward the screen centre, so the middle stays clear for camera/content.
/// Bass pulses at the corners, treble ripples outward into the frame.
final class PhyllotaxisCornersScene: VeloScene {

    let name = "Corner Bloom"

    private static let dots = 4000

    let draw = SceneDraw.points(PhyllotaxisCornersScene.dots)

    private var bins = [Float](repeating: 0, count: AudioEngine.binCount)
    private let attackPerSecond: Float = 18
    private let releasePerSecond: Float = 4

    func update(audio: AudioEngine, dt: Float) {
        let live = audio.currentBins()
        for i in 0..<bins.count {
            let target = live[i]
            let rate = target > bins[i] ? attackPerSecond : releasePerSecond
            bins[i] += (target - bins[i]) * min(rate * dt, 1)
        }
    }

    func writeData(into pointer: UnsafeMutableRawPointer) {
        bins.withUnsafeBufferPointer { buf in
            pointer.copyMemory(
                from: buf.baseAddress!,
                byteCount: AudioEngine.binCount * MemoryLayout<Float>.stride)
        }
    }

    var shaderSource: String {
        """
        \(Self.shaderPreamble)

        struct BloomData {
            float spectrum[128];
        };

        constant float GOLDEN = 2.39996323;
        constant float DOTS_PER_CORNER = \(Self.dots / 4).0;

        constant float2 CORNERS[4] = {
            float2(-1.0, -1.0),
            float2( 1.0, -1.0),
            float2(-1.0,  1.0),
            float2( 1.0,  1.0),
        };

        struct VSOut {
            float4 position [[position]];
            float  size     [[point_size]];
            float3 col;
            float  bright;
        };

        static inline float3 palette(float t) {
            return 0.5 + 0.5 * cos(6.28318 * (t + float3(0.0, 0.33, 0.67)));
        }

        vertex VSOut veloVertex(uint vid [[vertex_id]],
                                constant Uniforms &u [[buffer(0)]],
                                constant BloomData &s [[buffer(1)]])
        {
            int cornerIdx = int(vid) % 4;
            float i = float(int(vid) / 4);
            float frac = i / DOTS_PER_CORNER;
            float r = sqrt(frac);

            float cornerPhase = float(cornerIdx) * 1.5708;
            float theta = i * GOLDEN + u.time * 0.25 + cornerPhase;

            int binIdx = clamp(int(frac * 128.0), 0, 127);
            float spec = s.spectrum[binIdx];

            float rr = r * (0.65 + spec * 0.35);
            float aspect = u.resolution.x / max(u.resolution.y, 1.0);
            float2 offset = float2(cos(theta), sin(theta)) * rr;
            offset.x /= aspect;

            float2 p = CORNERS[cornerIdx] + offset;

            float dpi = max(u.resolution.y / 1080.0, 1.0);
            float distFromCenter = length(p);
            float fade = smoothstep(0.4, 1.0, distFromCenter);

            VSOut out;
            out.position = float4(p, 0.0, 1.0);
            out.size = mix(4.0, 14.0, spec) * (1.0 - r * 0.15) * dpi * fade;
            out.col = palette(frac * 0.8 + spec * 0.3 + u.time * 0.03);
            out.bright = (1.0 + spec * 2.0) * fade;
            return out;
        }

        fragment float4 veloFragment(VSOut in [[stage_in]],
                                     float2 pc [[point_coord]],
                                     constant Uniforms &u [[buffer(0)]])
        {
            float2 c = pc * 2.0 - 1.0;
            float d = dot(c, c);
            if (d > 1.0) { discard_fragment(); }
            float glow = exp(-d * 2.2);
            float3 gc = themeGrade(in.col, u);
            return float4(gc * in.bright * glow * u.dim, 1.0);
        }
        """
    }
}
