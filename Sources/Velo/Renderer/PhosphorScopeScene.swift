import Foundation

/// "Phosphor Scope" — ported from Android, where it is simply "Oscilloscope".
///
/// The opposite end of the scale from the Raw Oscilloscope, and renamed here so
/// the pair is legible in a flat list. Raw is a hairline that shows the signal
/// exactly as it is. This one is a CRT: a sub-pixel white filament inside a
/// coloured phosphor halo, with chromatic aberration growing toward the edges
/// and beam dwell dimming the fast transients, because a real beam spends less
/// time on a steep slope and so deposits less light there.
///
/// It also soft-clips hard. An unprocessed microphone is very quiet for speech,
/// so the trace is lifted 5x and then limited with a tanh, which brings a quiet
/// signal up without letting a clap slam into the top of the screen. That is a
/// deliberate difference from the Raw Oscilloscope's flat linear gain: this
/// scene is a look, and that one is a measurement.
final class PhosphorScopeScene: VeloScene {

    static let pointCount = 1024

    private static let shaderSensitivity: Double = 5.0
    private static let agcTarget: Float = 0.65
    private static let agcFloor: Float = 0.85
    private static let agcCeil: Float = 3.0
    private static let agcAttack: Float = 0.3
    private static let agcRelease: Float = 0.015
    private static let agcNoiseFloor: Float = 0.001

    let name = "Phosphor Scope"

    private var samples = [Float](repeating: 0, count: PhosphorScopeScene.pointCount)
    private var low: Float = 0
    private var smoothGain: Float = 0.85
    private var energy = BandEnergy()

    func update(audio: AudioEngine, dt: Float) {
        samples.withUnsafeMutableBufferPointer {
            audio.fillWaveform($0.baseAddress!, count: $0.count)
        }
        energy.update(bands: audio.currentBands(), dt: dt)
        low += (energy.low - low) * min(10 * dt, 1)

        // AGC ported from Android OscilloscopeScene: track the peak of the raw
        // PCM, compute the gain needed to bring the post-softclip amplitude to
        // the target, and ease toward it with asymmetric attack/release.
        var peak: Float = 0
        for s in samples { peak = max(peak, abs(s)) }
        peak = max(peak, Self.agcNoiseFloor)
        let postClip = Float(tanh(Double(peak) * Self.shaderSensitivity))
        let desired = min(max(Self.agcTarget / postClip, Self.agcFloor), Self.agcCeil)
        let alpha = desired < smoothGain ? Self.agcAttack : Self.agcRelease
        smoothGain += alpha * (desired - smoothGain)
    }

    func writeData(into pointer: UnsafeMutableRawPointer) {
        let bytes = Self.pointCount * MemoryLayout<Float>.stride
        samples.withUnsafeBufferPointer {
            pointer.copyMemory(from: $0.baseAddress!, byteCount: bytes)
        }
        var packed = SIMD2<Float>(low, smoothGain)
        pointer.advanced(by: bytes)
            .copyMemory(from: &packed, byteCount: MemoryLayout<SIMD2<Float>>.size)
    }

    var shaderSource: String {
        """
        \(Self.shaderPreamble)

        constant int POINTS = \(Self.pointCount);
        constant float N = float(\(Self.pointCount));
        constant float SENSITIVITY = 5.0;

        struct Trace { float sample[\(Self.pointCount)]; float low; float gain; };

        \(Self.fullscreenVertexShader)

        static inline float softClip(float x) {
            return tanh(clamp(x, -10.0, 10.0));
        }

        static inline float sampleY(constant Trace &t, int i) {
            return softClip(t.sample[clamp(i, 0, POINTS - 1)] * SENSITIVITY);
        }

        static inline float2 samplePx(constant Trace &t, int i, float xShift, float2 res) {
            float x = (float(i) / (N - 1.0)) * res.x + xShift;
            float y = (0.5 + 0.5 * sampleY(t, i) * t.gain) * res.y;
            return float2(x, y);
        }

        static inline float distToSegment(float2 p, float2 a, float2 b) {
            float2 pa = p - a;
            float2 ba = b - a;
            float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-5), 0.0, 1.0);
            return length(pa - ba * h);
        }

        // Minimum distance from the fragment to the trace, over a small window
        // of segments around the fragment's x. Five is enough for 1024 samples:
        // segments three or more away almost never contribute and cost about a
        // quarter of the loop's arithmetic.
        static inline float traceDistance(constant Trace &t, float2 fragPx,
                                          float xShift, float2 res) {
            float fx = (fragPx.x - xShift) / res.x * (N - 1.0);
            int centre = int(fx);
            float best = 1e9;
            for (int k = -2; k <= 2; k++) {
                int i = centre + k;
                if (i < 0 || i >= POINTS - 1) continue;
                best = min(best, distToSegment(fragPx,
                                               samplePx(t, i, xShift, res),
                                               samplePx(t, i + 1, xShift, res)));
            }
            return best;
        }

        fragment float4 veloFragment(VSOut in [[stage_in]],
                                     constant Uniforms &u [[buffer(0)]],
                                     constant Trace &t [[buffer(1)]])
        {
            float aspect = u.resolution.x / max(u.resolution.y, 1.0);

            // Burn-in protection: sample at a slowly orbiting offset.
            float2 orbit = float2(sin(u.time * 0.31) + 0.5 * sin(u.time * 0.13 + 1.7),
                                  cos(u.time * 0.27) + 0.5 * cos(u.time * 0.19 + 0.9)) * 1.5;
            float2 fragPx = float2(in.position.x, u.resolution.y - in.position.y) + orbit;

            // Halo radius, widened by the bass. Kept tight so this reads as a
            // fine neon filament with a soft glow, clearly distinct from the
            // flat hairline of the Raw Oscilloscope.
            float bloom = 4.5 * (1.0 + t.low * 1.2);

            float d0 = traceDistance(t, fragPx, 0.0, u.resolution);

            // Chromatic aberration grows toward the edges, scaled by bass. When
            // the shift is sub-pixel the outer channels are visually identical
            // to the centre, so the two extra scans are skipped entirely.
            float edge = abs((fragPx.x / u.resolution.x - 0.5) * 2.0);
            float ca = t.low * 6.0 * edge;
            float dCa, dCb;
            if (ca > 0.5) {
                dCa = traceDistance(t, fragPx,  ca, u.resolution);
                dCb = traceDistance(t, fragPx, -ca, u.resolution);
            } else {
                dCa = d0;
                dCb = d0;
            }

            // Heavy bass drives the core well past 1.0.
            float hdrGain = 1.0 + t.low * 4.0;

            // Sub-pixel ultra-bright white filament.
            float coreSig = 0.6;
            float core = exp(-(d0 * d0) / (2.0 * coreSig * coreSig));

            // Coloured phosphor halo, split per channel for the analogue fringe.
            float3 phosphor = float3(0.45, 1.0, 0.65);
            float3 halo = float3(exp(-dCa / bloom),
                                 exp(-d0  / bloom),
                                 exp(-dCb / bloom)) * phosphor;

            float3 col = float3(core * hdrGain) + halo * 0.55;

            // Beam dwell: a real beam spends less time on a steep slope, so a
            // fast transient deposits less light. Reuses the centre channel's x
            // rather than looking it up again.
            float fx = fragPx.x / u.resolution.x * (N - 1.0);
            int c = clamp(int(fx), 0, POINTS - 2);
            float vel = abs(sampleY(t, c + 1) - sampleY(t, c));
            col *= mix(0.35, 1.0, 1.0 / (1.0 + vel * 8.0));

            // Aspect-correct vignette, for the analogue feel.
            float2 cc = (fragPx / u.resolution - 0.5);
            cc.x *= aspect;
            col *= smoothstep(1.15, 0.25, length(cc));

            return float4(themeGrade(col, u) * u.dim, 1.0);
        }
        """
    }
}
