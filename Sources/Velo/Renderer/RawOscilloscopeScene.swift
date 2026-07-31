import Foundation

/// "Raw Oscilloscope" — ported from Android.
///
/// The opposite of a phosphor scope: a single thin trace drawn straight from the
/// PCM window at flat linear gain. No glow, no bloom, no soft clip, no burn-in
/// orbit, no vignette. Every sample is plotted as it is, so the trace shows all
/// the fine detail of the waveform. Just the signal.
///
/// One thing had to change in the port. Android draws `GL_LINE_STRIP` at width
/// 1, but Metal has no line width at all — a `lineStrip` is always one pixel,
/// which on a Retina drawable is half a point and aliases into a dotted mess.
/// So the trace is rasterized in the fragment shader as a distance field: for
/// each pixel, the true distance to the nearest waveform SEGMENT. That gives a
/// constant pixel width and proper antialiasing at any resolution, and it
/// cannot miss a peak between samples the way point sampling would.
final class RawOscilloscopeScene: VeloScene {

    static let pointCount = 1024

    let name = "Raw Oscilloscope"

    private var samples = [Float](repeating: 0, count: RawOscilloscopeScene.pointCount)

    func update(audio: AudioEngine, dt: Float) {
        // Deliberately unsmoothed: this scene's whole point is that nothing sits
        // between the converter and the line.
        samples.withUnsafeMutableBufferPointer { buffer in
            audio.fillWaveform(buffer.baseAddress!, count: buffer.count)
        }
    }

    func writeData(into pointer: UnsafeMutableRawPointer) {
        samples.withUnsafeBufferPointer {
            pointer.copyMemory(
                from: $0.baseAddress!,
                byteCount: $0.count * MemoryLayout<Float>.stride
            )
        }
    }

    var shaderSource: String {
        """
        \(Self.shaderPreamble)

        constant int POINTS = \(Self.pointCount);

        struct Trace { float sample[\(Self.pointCount)]; };

        \(Self.fullscreenVertexShader)

        // Distance from p to segment ab, in pixels.
        static inline float sdSegment(float2 p, float2 a, float2 b) {
            float2 pa = p - a;
            float2 ba = b - a;
            float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-6), 0.0, 1.0);
            return length(pa - ba * h);
        }

        fragment float4 veloFragment(VSOut in [[stage_in]],
                                     constant Uniforms &u [[buffer(0)]],
                                     constant Trace &t [[buffer(1)]])
        {
            // Flat linear gain, as on Android: no compression, no clipping, so a
            // hot signal genuinely runs off the top rather than being flattered.
            constexpr float GAIN = 2.5;
            constexpr float HALF_WIDTH = 1.1;   // trace half-thickness, in pixels
            constexpr float AA = 1.0;

            // Origin bottom-left so the trace sits the right way up.
            float2 p = float2(in.position.x, u.resolution.y - in.position.y);

            float mid = u.resolution.y * 0.5;
            float amp = u.resolution.y * 0.5 * GAIN;
            float pxPerSample = u.resolution.x / float(POINTS - 1);

            // Only the segments that could possibly be nearest this pixel. The
            // window widens when a sample spans less than a pixel, so the trace
            // stays continuous when the drawable is narrower than the PCM window.
            int span = max(int(ceil(1.0 / max(pxPerSample, 1e-4))), 1) + 1;
            int centre = int(p.x / max(pxPerSample, 1e-4));
            int lo = max(centre - span, 0);
            int hi = min(centre + span, POINTS - 2);

            float best = 1e9;
            for (int i = lo; i <= hi; i++) {
                float2 a = float2(float(i) * pxPerSample, mid + t.sample[i] * amp);
                float2 b = float2(float(i + 1) * pxPerSample, mid + t.sample[i + 1] * amp);
                best = min(best, sdSegment(p, a, b));
            }

            float line = smoothstep(HALF_WIDTH + AA, HALF_WIDTH - AA, best);

            // On-brand green, driven well past 1.0. The scene bypasses any bloom
            // and writes straight to the surface, so >1 simply means peak nits
            // on an HDR display and clamps harmlessly on an SDR one. Scaling the
            // whole colour keeps the hue intact instead of drifting to white.
            constexpr float HDR_BOOST = 10.0;
            float3 col = float3(0.149, 1.0, 0.549) * HDR_BOOST * line;
            return float4(themeGrade(col, u) * u.dim, 1.0);
        }
        """
    }
}
