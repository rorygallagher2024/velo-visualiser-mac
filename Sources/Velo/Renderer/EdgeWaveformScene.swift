import Foundation

/// "Edge Waveform" — the live audio waveform rendered as a glowing line tracing
/// the perimeter of the screen like a picture frame.
///
/// A rolling window of PCM samples wraps continuously around all four edges:
/// bottom-left → bottom-right → up the right → across the top (reversed) → down
/// the left. The displacement is perpendicular to the edge (inward), so the
/// waveform breathes toward the centre on loud passages but the centre itself
/// stays clear. A bright core with a soft bloom sells the neon-tube look.
final class EdgeWaveformScene: VeloScene {

    let name = "Edge Waveform"

    private static let sampleCount = 1024
    private var samples = [Float](repeating: 0, count: sampleCount)
    private var energy = BandEnergy()

    func update(audio: AudioEngine, dt: Float) {
        energy.update(bands: audio.currentBands(), dt: dt)
        samples.withUnsafeMutableBufferPointer { buf in
            audio.fillWaveform(buf.baseAddress!, count: buf.count)
        }
    }

    func writeData(into pointer: UnsafeMutableRawPointer) {
        let p = pointer.bindMemory(to: Float.self, capacity: 3 + Self.sampleCount)
        p[0] = energy.low
        p[1] = energy.mid
        p[2] = energy.envelope
        samples.withUnsafeBufferPointer { buf in
            (pointer + 3 * MemoryLayout<Float>.stride).copyMemory(
                from: buf.baseAddress!,
                byteCount: Self.sampleCount * MemoryLayout<Float>.stride)
        }
    }

    var shaderSource: String {
        """
        \(Self.shaderPreamble)

        struct WaveData {
            float low;
            float mid;
            float envelope;
            float pcm[\(Self.sampleCount)];
        };

        \(Self.fullscreenVertexShader)

        fragment float4 veloFragment(VSOut in [[stage_in]],
                                     constant Uniforms &u [[buffer(0)]],
                                     constant WaveData &s [[buffer(1)]])
        {
            float2 fc = float2(in.position.x, u.resolution.y - in.position.y);
            float2 uv = fc / u.resolution;

            float dLeft   = uv.x;
            float dRight  = 1.0 - uv.x;
            float dBottom = uv.y;
            float dTop    = 1.0 - uv.y;

            // Which edge and position along it (0..1).
            float edgeDist;
            float along;
            int   edge;

            if (dBottom <= dLeft && dBottom <= dRight && dBottom <= dTop) {
                edge = 0; edgeDist = dBottom; along = uv.x;
            } else if (dRight <= dLeft && dRight <= dTop) {
                edge = 1; edgeDist = dRight; along = uv.y;
            } else if (dTop <= dLeft) {
                edge = 2; edgeDist = dTop; along = 1.0 - uv.x;
            } else {
                edge = 3; edgeDist = dLeft; along = 1.0 - uv.y;
            }

            // Perimeter fraction: bottom → right → top → left = 0..1.
            float perim = (float(edge) + along) / 4.0;

            // Sample the waveform at this perimeter position.
            float fi = perim * float(\(Self.sampleCount) - 1);
            int i0 = clamp(int(fi), 0, \(Self.sampleCount) - 2);
            float frac = fi - float(i0);
            float wave = mix(s.pcm[i0], s.pcm[i0 + 1], frac);

            // Displacement from edge: the waveform pushes inward.
            // Baseline sits slightly inside the edge so silence isn't invisible.
            // Toned down to be more subtle and tasteful.
            float amplitude = 0.04 + s.envelope * 0.03;
            float baseline = 0.015;
            float disp = baseline + wave * amplitude;

            // Signed distance from the waveform line.
            float dist = edgeDist - disp;

            // Core line: slightly softened so it's not aggressively harsh.
            float px = 1.5 / u.resolution.y;
            float core = exp(-abs(dist) / max(px * 1.8, 0.001)) * 0.8;

            // Bloom: softer, wider glow, less intense.
            float bloom = exp(-abs(dist) * 16.0) * 0.4;

            float intensity = core + bloom;

            // Colour shifts with frequency position: warm bass, cool treble.
            float3 bassCol   = float3(1.0, 0.25, 0.08);
            float3 midCol    = float3(0.2, 1.0, 0.5);
            float3 trebleCol = float3(0.15, 0.55, 1.0);
            float t = perim;
            float3 col;
            if (t < 0.5) {
                col = mix(bassCol, midCol, t * 2.0);
            } else {
                col = mix(midCol, trebleCol, (t - 0.5) * 2.0);
            }

            // Subtle beat brighten (removed aggressive strobe).
            col *= 1.0 + s.envelope * 0.3;

            col *= intensity;

            // Corner fade to avoid harsh seams.
            float cornerFade = smoothstep(0.0, 0.03, min(along, 1.0 - along));
            col *= cornerFade;

            return float4(themeGrade(col, u) * u.dim, 1.0);
        }
        """
    }
}
