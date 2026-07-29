import Foundation

/// "Spectrum Analyser" — the first scene, ported from the Android app.
///
/// Thirty-one bands, because that is the third-octave standard a real RTA uses
/// rather than a number picked to fill the screen. Each band carries a slender
/// column and a hairline cap that holds its recent maximum and then falls away
/// under gravity. The caps are the whole point: they turn a wall of moving bars
/// into something you can read, because the shape of a mix stays legible for a
/// moment after the transient that made it has gone.
///
/// Ballistics are peak-programme — snap up, glide down. A bar is a PPM, not a
/// VU: nothing here springs, because a bar has no mass to overshoot with.
///
/// Deliberately monochrome and deliberately without a red zone. There is no
/// per-band equivalent of clipping to claim, so a loud band is just a loud band.
final class SpectrumAnalyserScene: VeloScene {

    static let bandCount = 31

    let name = "Spectrum Analyser"

    private(set) var levels = [Float](repeating: 0, count: bandCount)
    private(set) var peaks = [Float](repeating: 0, count: bandCount)
    private var peakVelocity = [Float](repeating: 0, count: bandCount)
    private var peakHold = [Float](repeating: 0, count: bandCount)

    private let attackRate: Float = 60    // ~17 ms: effectively instant
    private let releaseRate: Float = 12   // ~83 ms; the caps carry the memory
    private let peakHoldSec: Float = 0.6
    private let peakGravity: Float = 1.6  // scale-units per second squared

    /// Advance the ballistics from the analyser's band magnitudes (0...1).
    func update(audio: AudioEngine, dt: Float) {
        let bands = audio.currentBands()
        guard bands.count == Self.bandCount else { return }
        for i in 0..<Self.bandCount {
            let target = bands[i]
            let rate = target >= levels[i] ? attackRate : releaseRate
            levels[i] += (target - levels[i]) * min(rate * dt, 1)

            let shown = levels[i]
            if shown >= peaks[i] {
                peaks[i] = shown
                peakVelocity[i] = 0
                peakHold[i] = peakHoldSec
            } else if peakHold[i] > 0 {
                peakHold[i] -= dt
            } else {
                peakVelocity[i] += peakGravity * dt
                peaks[i] = max(shown, peaks[i] - peakVelocity[i] * dt)
            }
        }
    }

    func writeData(into pointer: UnsafeMutableRawPointer) {
        let bytes = Self.bandCount * MemoryLayout<Float>.stride
        levels.withUnsafeBufferPointer { pointer.copyMemory(from: $0.baseAddress!, byteCount: bytes) }
        peaks.withUnsafeBufferPointer {
            pointer.advanced(by: bytes).copyMemory(from: $0.baseAddress!, byteCount: bytes)
        }
    }

    /// Metal Shading Language source, compiled at launch.
    ///
    /// Everything is measured in pixels so the anti-alias width can be a
    /// constant. `fwidth` is unusable here: the band index comes from a
    /// `floor()`, which jumps a whole cell at every boundary and would scatter
    /// stray lines along the column edges.
    var shaderSource: String {
        """
    \(Self.shaderPreamble)

    struct Bands {
        float level[31];
        float peak[31];
    };

    \(Self.fullscreenVertexShader)

    static inline float sdRoundBox(float2 p, float2 b, float r) {
        float2 d = abs(p) - b + r;
        return min(max(d.x, d.y), 0.0) + length(max(d, 0.0)) - r;
    }

    fragment float4 veloFragment(VSOut in [[stage_in]],
                                 constant Uniforms &u [[buffer(0)]],
                                 constant Bands &b [[buffer(1)]])
    {
        constexpr int   BANDS     = 31;
        constexpr float BASE_FRAC = 0.10;   // baseline height, fraction of screen
        constexpr float TOP_FRAC  = 0.90;   // full-scale height
        constexpr float MARGIN    = 0.055;  // side margin, fraction of width
        constexpr float BAR_FILL  = 0.60;   // column width within its cell
        constexpr float AA        = 1.2;    // edge softness, in pixels

        // Metal's framebuffer origin is top-left; flip so the analyser stands up.
        float2 p = float2(in.position.x, u.resolution.y - in.position.y);

        // OLED burn-in protection: the instrument drifts on a slow orbit.
        p -= float2(sin(u.time * 0.31) + 0.5 * sin(u.time * 0.13 + 1.7),
                    cos(u.time * 0.27) + 0.5 * cos(u.time * 0.19 + 0.9)) * 1.5;

        float baseY  = u.resolution.y * BASE_FRAC;
        float span   = u.resolution.y * TOP_FRAC - baseY;
        float x0     = u.resolution.x * MARGIN;
        float fieldW = u.resolution.x * (1.0 - 2.0 * MARGIN);
        float cellW  = fieldW / float(BANDS);
        float halfW  = cellW * BAR_FILL * 0.5;

        float3 col = float3(0.0);

        // Whisper baseline: grounds the columns without drawing a frame.
        float dBase = sdRoundBox(p - float2(x0 + fieldW * 0.5, baseY),
                                 float2(fieldW * 0.5, 0.6), 0.5);
        col += float3(0.055) * smoothstep(AA, -AA, dBase);

        int bi = int(floor((p.x - x0) / cellW));
        if (bi >= 0 && bi < BANDS) {
            float cx = x0 + (float(bi) + 0.5) * cellW;

            // The column, rounded at the crest, collapsing to a sliver at rest.
            float hh = max(b.level[bi] * span * 0.5, 0.0);
            float dBar = sdRoundBox(p - float2(cx, baseY + hh),
                                    float2(halfW, hh), min(halfW * 0.6, hh));
            col += float3(1.0) * smoothstep(AA, -AA, dBar) * 1.2;

            // The cap: dimmer than the column so it reads as memory, not level.
            float dPk = sdRoundBox(p - float2(cx, baseY + b.peak[bi] * span),
                                   float2(halfW, 1.1), 0.9);
            col += float3(0.34) * smoothstep(AA, -AA, dPk);
        }

        return float4(col * u.dim, 1.0);
    }
    """
    }
}
