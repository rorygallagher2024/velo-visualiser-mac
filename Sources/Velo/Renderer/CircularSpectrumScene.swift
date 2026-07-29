import Foundation

/// "Circular Spectrum" — ported from Android.
///
/// A precise circle in the centre of the screen extruded outward into 128
/// segmented bars, one per log-spaced bin, so the lows don't swamp the picture.
/// Each bar carries a gravity peak-hold dot that falls slower than the bar
/// itself, which is what makes the shape of a mix readable a moment after the
/// transient that made it.
///
/// One fullscreen fragment pass: the fragment's polar angle picks the bin, so
/// there is no geometry to build and nothing to tessellate.
final class CircularSpectrumScene: VeloScene {

    static let bins = AudioEngine.binCount

    let name = "Circular Spectrum"

    private var bars = ColumnBallistics(count: CircularSpectrumScene.bins)

    init() {
        bars.attackRate = 60      // ~17 ms: effectively instant
        bars.releaseRate = 10
        bars.peakHoldSec = 0.5
        bars.peakGravity = 1.4
    }

    func update(audio: AudioEngine, dt: Float) {
        bars.update(targets: audio.currentBins(), dt: dt)
    }

    func writeData(into pointer: UnsafeMutableRawPointer) { bars.write(into: pointer) }

    var shaderSource: String {
        """
        \(Self.shaderPreamble)

        struct Ring {
            float level[\(Self.bins)];
            float peak[\(Self.bins)];
        };

        \(Self.fullscreenVertexShader)

        static inline float3 palette(float t) {
            return 0.5 + 0.5 * cos(6.28318 * (t + float3(0.0, 0.33, 0.67)));
        }

        fragment float4 veloFragment(VSOut in [[stage_in]],
                                     constant Uniforms &u [[buffer(0)]],
                                     constant Ring &r [[buffer(1)]])
        {
            constexpr int   BINS  = \(Self.bins);
            // INNER + MAXLEN (plus the peak dot) must stay under 0.5 so the ring
            // never touches the shorter screen edge.
            constexpr float INNER  = 0.14;
            constexpr float MAXLEN = 0.30;

            // Normalised by the SHORTER axis: the ring stays perfectly round AND
            // fits any window shape without clipping.
            float2 p = float2(in.position.x, u.resolution.y - in.position.y);
            float2 uv = (p - 0.5 * u.resolution) / min(u.resolution.x, u.resolution.y);

            float radius = length(uv);
            float angle = atan2(uv.y, uv.x) / 6.28318 + 0.5;   // 0..1 around the circle
            float fbin = angle * float(BINS);
            float seg = fract(fbin);                            // 0..1 within a bar
            int idx = clamp(int(floor(fbin)), 0, BINS - 1);

            float mag = r.level[idx];
            float peak = r.peak[idx];

            // Angular gap between adjacent bars.
            float barMask = step(0.12, seg) * step(seg, 0.88);

            float3 col = float3(0.0);

            // Bar fill, brighter toward the tip so it blooms past 1.0.
            float barTop = INNER + mag * MAXLEN;
            if (radius > INNER && radius < barTop) {
                float t = (radius - INNER) / MAXLEN;
                col = palette(t * 0.5 + 0.05) * barMask * (1.0 + t * 1.5);
            }

            // Gravity peak-hold dot.
            float peakR = INNER + peak * MAXLEN;
            if (abs(radius - peakR) < 0.008) {
                col += float3(1.0) * barMask * 2.0;
            }

            // Thin inner ring outline.
            col += float3(0.2, 0.5, 0.8) * smoothstep(0.004, 0.0, abs(radius - INNER));

            return float4(col * u.dim, 1.0);
        }
        """
    }
}
