import Foundation

/// "Pocket LED" — ported from Android.
///
/// A dot-matrix spectrum panel with the mechanical meter's craft rather than its
/// palette: honest instrument physics, an idle standby, and the shared burn-in
/// orbit, expressed as a grid of LED segments. The colour is the hardware-meter
/// ladder — green low, amber mid, red hot up each column.
///
/// Each column is bottom-anchored with instant attack and a smooth release, and
/// carries one peak-hold cell that hovers, holds, then falls under gravity like
/// a hi-fi peak pointer. Unlit cells glow faintly so the matrix reads as a
/// physical panel; the crest and the cap run past 1.0 so they bloom on an HDR
/// display. After a few seconds of silence the panel settles to a resting glow
/// and snaps awake on the first signal.
///
/// Android carries the ballistics in a COLS x 2 texture. Here they are two runs
/// of floats in the shared scene buffer — a texture for 48 values would be a
/// sampler and an upload for nothing.
final class PocketLedScene: VeloScene {

    static let cols = 24
    static let rows = 14

    let name = "Pocket LED"

    private var bar = [Float](repeating: 0, count: PocketLedScene.cols)
    private var peak = [Float](repeating: 0, count: PocketLedScene.cols)
    private var peakHold = [Float](repeating: 0, count: PocketLedScene.cols)
    private var peakVelocity = [Float](repeating: 0, count: PocketLedScene.cols)
    private var idleGlow: Float = 1
    private var silentSeconds: Float = 0

    private let releaseTau: Float = 0.14      // snaps up instantly, eases down this fast
    private let peakHoldSec: Float = 0.7
    private let peakGravity: Float = 1.1      // dial-fractions per second squared
    private let idleSilence: Float = 0.02
    private let idleAfterSec: Float = 3
    private let idleGlowFloor: Float = 0.4
    private let idleFallRate: Float = 1.2     // ease into idle, ~1.5 s
    private let idleWakeRate: Float = 9       // snap awake, ~0.15 s

    func update(audio: AudioEngine, dt: Float) {
        let bins = audio.currentBins()
        guard bins.count == AudioEngine.binCount else { return }

        let fall = 1 - exp(-dt / releaseTau)
        var loudest: Float = 0
        for i in 0..<Self.cols {
            let lo = i * AudioEngine.binCount / Self.cols
            let hi = max((i + 1) * AudioEngine.binCount / Self.cols, lo + 1)
            var sum: Float = 0
            for j in lo..<hi { sum += bins[min(j, AudioEngine.binCount - 1)] }
            let raw = sum / Float(hi - lo)
            loudest = max(loudest, raw)

            // Instant attack — an LED has no mass — and a smooth release.
            bar[i] = raw >= bar[i] ? raw : bar[i] + (raw - bar[i]) * fall
            advancePeak(i, dt: dt)
        }
        advanceIdle(loudest: loudest, dt: dt)
    }

    private func advancePeak(_ i: Int, dt: Float) {
        if bar[i] >= peak[i] {
            peak[i] = bar[i]
            peakVelocity[i] = 0
            peakHold[i] = peakHoldSec
        } else if peakHold[i] > 0 {
            peakHold[i] -= dt
        } else {
            peakVelocity[i] += peakGravity * dt
            peak[i] = max(bar[i], peak[i] - peakVelocity[i] * dt)
        }
    }

    private func advanceIdle(loudest: Float, dt: Float) {
        silentSeconds = loudest < idleSilence ? silentSeconds + dt : 0
        let target: Float = silentSeconds > idleAfterSec ? idleGlowFloor : 1
        let rate = target > idleGlow ? idleWakeRate : idleFallRate
        idleGlow += (target - idleGlow) * min(rate * dt, 1)
    }

    func writeData(into pointer: UnsafeMutableRawPointer) {
        let bytes = Self.cols * MemoryLayout<Float>.stride
        bar.withUnsafeBufferPointer { pointer.copyMemory(from: $0.baseAddress!, byteCount: bytes) }
        peak.withUnsafeBufferPointer {
            pointer.advanced(by: bytes).copyMemory(from: $0.baseAddress!, byteCount: bytes)
        }
        // The idle glow rides along as one more float rather than as a uniform:
        // the scene buffer is already per-frame and already bound.
        var glow = idleGlow
        pointer.advanced(by: bytes * 2)
            .copyMemory(from: &glow, byteCount: MemoryLayout<Float>.stride)
    }

    var shaderSource: String {
        """
        \(Self.shaderPreamble)

        struct Panel {
            float bar[\(Self.cols)];
            float peak[\(Self.cols)];
            float glow;
        };

        \(Self.fullscreenVertexShader)

        static inline float sdRoundBox(float2 p, float2 b, float r) {
            float2 d = abs(p) - b + r;
            return min(max(d.x, d.y), 0.0) + length(max(d, 0.0)) - r;
        }

        // Classic LED VU colours by height: green low, amber mid, red hot, with a
        // hair of blend so the boundaries antialias instead of banding.
        static inline float3 ledColor(float rowFrac) {
            constexpr float3 GREEN = float3(0.15, 1.0, 0.30);
            constexpr float3 AMBER = float3(1.0, 0.72, 0.10);
            constexpr float3 RED   = float3(1.0, 0.18, 0.13);
            float3 c = mix(GREEN, AMBER, smoothstep(0.56, 0.60, rowFrac));
            return mix(c, RED, smoothstep(0.80, 0.84, rowFrac));
        }

        fragment float4 veloFragment(VSOut in [[stage_in]],
                                     constant Uniforms &u [[buffer(0)]],
                                     constant Panel &p [[buffer(1)]])
        {
            constexpr int   COLS   = \(Self.cols);
            constexpr int   ROWS   = \(Self.rows);
            constexpr float MARGIN = 0.16;   // gap between segments, cell units
            constexpr float CORNER = 0.12;   // segment corner radius, cell units
            constexpr float3 PEAK_TINT = float3(1.0, 0.95, 0.85);

            // Origin bottom-left so the columns stand up.
            float2 uv = float2(in.position.x, u.resolution.y - in.position.y) / u.resolution;

            // Burn-in protection: the whole panel drifts on a slow orbit.
            uv += float2(sin(u.time * 0.31) + 0.5 * sin(u.time * 0.13 + 1.7),
                         cos(u.time * 0.27) + 0.5 * cos(u.time * 0.19 + 0.9)) * 0.0012;

            float2 grid = float2(float(COLS), float(ROWS));
            float2 f = uv * grid;
            float2 ci = floor(f);
            if (any(ci < 0.0) || any(ci >= grid)) { return float4(0.0, 0.0, 0.0, 1.0); }

            // Rounded, antialiased LED segment inside the cell.
            float2 cell = fract(f) - 0.5;
            float d = sdRoundBox(cell, float2(0.5 - MARGIN), CORNER);
            float aa = fwidth(d) + 1e-4;
            float shape = smoothstep(aa, -aa, d);
            if (shape < 0.001) { return float4(0.0, 0.0, 0.0, 1.0); }

            int col = int(ci.x);
            float bar = p.bar[col];
            float peak = p.peak[col];

            float rowFrac = (ci.y + 0.5) / float(ROWS);
            // Fractional fill: whole cells below the crest are full and the tip
            // cell fades by the remainder, so the bar top is smooth, not steppy.
            float fill = clamp(bar * float(ROWS) - ci.y, 0.0, 1.0);
            float peakRow = floor(peak * float(ROWS) - 0.001);
            float isPeak = step(abs(ci.y - peakRow), 0.001) * step(0.02, peak);

            float3 zone = ledColor(rowFrac);
            float3 lit = zone * (0.85 + rowFrac * 1.4);

            float3 c = zone * 0.035;                  // resting glow, keeps the zone tint
            c = mix(c, lit, fill);
            // Peak cap: a paler, hotter shade of the bar's own colour. Kept
            // modest so the channels don't all clamp and wash it out to white.
            c = mix(c, mix(zone, PEAK_TINT, 0.25) * 1.7, isPeak);

            return float4(c * shape * u.dim * p.glow, 1.0);
        }
        """
    }
}
