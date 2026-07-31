import Foundation

/// "Spectrum Bars" — ported from Android, where it is "Spectrum Bars Retro".
///
/// The classic analyser: 48 wide bars in a hue ramp, each with a gravity peak
/// cap, on a thin baseline glow. Where the Spectrum Analyser is deliberately
/// monochrome and instrument-like, this one is colour and nostalgia, and it
/// fills the frame edge to edge in plain normalised screen space rather than
/// keeping instrument margins.
final class BarSpectrumScene: VeloScene {

    static let bins = 48

    let name = "Spectrum Bars"

    private var bars = ColumnBallistics(count: BarSpectrumScene.bins)

    init() {
        bars.attackRate = 60
        bars.releaseRate = 10
        bars.peakHoldSec = 0.5
        bars.peakGravity = 1.4
    }

    func update(audio: AudioEngine, dt: Float) {
        bars.update(targets: ColumnBallistics.fold(audio.currentBins(), into: Self.bins), dt: dt)
    }

    func writeData(into pointer: UnsafeMutableRawPointer) { bars.write(into: pointer) }

    var shaderSource: String {
        """
        \(Self.shaderPreamble)

        struct Bars { float level[\(Self.bins)]; float peak[\(Self.bins)]; };

        \(Self.fullscreenVertexShader)

        static inline float3 palette(float t) {
            return 0.5 + 0.5 * cos(6.28318 * (t + float3(0.0, 0.33, 0.67)));
        }

        fragment float4 veloFragment(VSOut in [[stage_in]],
                                     constant Uniforms &u [[buffer(0)]],
                                     constant Bars &b [[buffer(1)]])
        {
            constexpr int   BINS    = \(Self.bins);
            constexpr float FLOOR_Y = 0.06;   // bottom margin
            constexpr float CEIL_Y  = 0.94;   // top margin, so bars never clip

            // Plain normalised screen space: fills any resolution and aspect.
            float2 uv = float2(in.position.x, u.resolution.y - in.position.y) / u.resolution;

            float fbin = uv.x * float(BINS);
            float seg = fract(fbin);                      // 0..1 within a bar cell
            int idx = clamp(int(floor(fbin)), 0, BINS - 1);

            float mag = b.level[idx];
            float peak = b.peak[idx];

            float span = CEIL_Y - FLOOR_Y;
            float barTop = FLOOR_Y + mag * span;
            float peakY = FLOOR_Y + peak * span;

            float barMask = step(0.08, seg) * step(seg, 0.92);   // gaps between bars

            float3 col = float3(0.0);

            // Bar fill: hue and brightness both ramp up the bar, so the tip
            // runs past 1.0 and blooms.
            if (uv.y > FLOOR_Y && uv.y < barTop) {
                float h = (uv.y - FLOOR_Y) / span;
                col = palette(0.62 - h * 0.45) * barMask * (0.5 + h * 1.5);
                col *= 1.0 + h * 1.2;
            }

            // Gravity peak cap.
            if (abs(uv.y - peakY) < 0.006 && peak > 0.01) {
                col += float3(1.0) * barMask * 1.8;
            }

            // Baseline glow.
            col += float3(0.1, 0.35, 0.55) * smoothstep(0.004, 0.0, abs(uv.y - FLOOR_Y));

            return float4(themeGrade(col, u) * u.dim, 1.0);
        }
        """
    }
}
