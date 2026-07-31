import Foundation

/// "Phyllotaxis Bloom" — ported from Android.
///
/// A sunflower spiral laid out on the golden angle. Each dot owns one FFT bin,
/// centre to rim mapping lows to highs, so its size, colour and outward push
/// all track that band. The bloom turns slowly and breathes with the music.
///
/// Every dot's position comes from its own index, so this is a point-sprite
/// scene with nothing to upload but the spectrum — the same shape the Android
/// original has, which derives positions from `gl_VertexID` and reads the
/// spectrum through a vertex texture fetch. Here the bins ride in the shared
/// scene buffer instead, which avoids the texture upload that was measured
/// serialising the queue for the Spectrogram.
final class PhyllotaxisScene: VeloScene {

    let name = "Phyllotaxis Bloom"

    /// More than Android's 900. The spiral is sampled per dot, so a denser
    /// bloom reads better on a canvas several times the size without changing
    /// the arrangement.
    private static let dots = 1400

    let draw = SceneDraw.points(PhyllotaxisScene.dots)

    private var bins = [Float](repeating: 0, count: AudioEngine.binCount)

    /// Per-bin ballistics, in seconds rather than frames, so the bloom breathes
    /// at the same rate at 60 and 240 fps. Raw bins jitter a dot's size frame
    /// to frame; the Android original leans on SpectrumData for the same
    /// smoothing, which this app deliberately keeps in the scenes instead.
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

        constant float GOLDEN = 2.39996323;   // the golden angle, in radians
        constant float DOTS   = \(Self.dots).0;

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
            float i = float(vid);
            float frac = i / DOTS;              // 0 at the centre, 1 at the rim
            float r = sqrt(frac);               // even area, not even radius
            float theta = i * GOLDEN + u.time * 0.25;

            int binIdx = clamp(int(frac * 128.0), 0, 127);
            float spec = s.spectrum[binIdx];

            float rr = r * (0.82 + spec * 0.5); // band energy pushes dots out
            float aspect = u.resolution.x / max(u.resolution.y, 1.0);
            float2 p = float2(cos(theta), sin(theta)) * rr;
            p.x /= aspect;                      // keep the bloom round

            // Sizes are pixels at a 1080-tall reference. Left unscaled a dot
            // would be a quarter the apparent size on a 4K canvas.
            float dpi = max(u.resolution.y / 1080.0, 1.0);

            VSOut out;
            out.position = float4(p, 0.0, 1.0);
            out.size = mix(5.0, 16.0, spec) * (1.0 - r * 0.2) * dpi;
            out.col = palette(frac * 0.8 + spec * 0.3 + u.time * 0.03);
            // Every dot reaches into HDR; loud bins push much brighter.
            out.bright = 1.2 + spec * 2.2;
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
