import Foundation

/// "Edge Equaliser" — spectrum bars growing inward from all four screen edges.
///
/// The 128 FFT bins are mapped around the perimeter: bass along the bottom,
/// mids up the sides, treble along the top. Each bin is a glowing bar whose
/// length tracks its energy. The centre stays completely clear for camera or
/// content overlays — this is an analyser that doubles as a decorative frame.
final class EdgeEqualiserScene: VeloScene {

    let name = "Edge Equaliser"

    private var bins = [Float](repeating: 0, count: AudioEngine.binCount)
    private var energy = BandEnergy()

    private let attackPerSecond: Float = 20
    private let releasePerSecond: Float = 5

    func update(audio: AudioEngine, dt: Float) {
        energy.update(bands: audio.currentBands(), dt: dt)
        let live = audio.currentBins()
        for i in 0..<bins.count {
            let target = live[i]
            let rate = target > bins[i] ? attackPerSecond : releasePerSecond
            bins[i] += (target - bins[i]) * min(rate * dt, 1)
        }
    }

    func writeData(into pointer: UnsafeMutableRawPointer) {
        let p = pointer.bindMemory(to: Float.self, capacity: AudioEngine.binCount + 1)
        p[0] = energy.envelope
        bins.withUnsafeBufferPointer { buf in
            (pointer + MemoryLayout<Float>.stride).copyMemory(
                from: buf.baseAddress!,
                byteCount: AudioEngine.binCount * MemoryLayout<Float>.stride)
        }
    }

    var shaderSource: String {
        """
        \(Self.shaderPreamble)

        struct EqData {
            float envelope;
            float spectrum[128];
        };

        \(Self.fullscreenVertexShader)

        fragment float4 veloFragment(VSOut in [[stage_in]],
                                     constant Uniforms &u [[buffer(0)]],
                                     constant EqData &s [[buffer(1)]])
        {
            float2 fc = float2(in.position.x, u.resolution.y - in.position.y);
            float2 uv = fc / u.resolution;
            float aspect = u.resolution.x / max(u.resolution.y, 1.0);

            // Distance from each edge (0 at edge, 1 at centre), in UV space.
            float dLeft   = uv.x;
            float dRight  = 1.0 - uv.x;
            float dBottom = uv.y;
            float dTop    = 1.0 - uv.y;

            // Which edge is closest, and how far along that edge (0..1)?
            float edgeDist;
            float along;   // fractional position along the edge
            int   edge;    // 0=bottom, 1=right, 2=top, 3=left

            if (dBottom <= dLeft && dBottom <= dRight && dBottom <= dTop) {
                edge = 0; edgeDist = dBottom; along = uv.x;
            } else if (dRight <= dLeft && dRight <= dTop) {
                edge = 1; edgeDist = dRight; along = uv.y;
            } else if (dTop <= dLeft) {
                edge = 2; edgeDist = dTop; along = 1.0 - uv.x;
            } else {
                edge = 3; edgeDist = dLeft; along = 1.0 - uv.y;
            }

            // Map perimeter position to bin index.
            // Bottom: bins 0..31 (bass), Right: 32..63, Top: 64..95 (treble),
            // Left: 96..127.
            float perimFrac = (float(edge) + along) / 4.0;
            int bin = clamp(int(perimFrac * 128.0), 0, 127);

            float val = s.spectrum[bin];

            // Bar extends inward from edge. Max depth ~18% of screen height.
            float maxDepth = 0.18;
            float barDepth = val * maxDepth;

            // Hard bar body with a soft glow halo beyond it.
            float barMask = smoothstep(barDepth + 0.003, barDepth, edgeDist);
            float glowMask = exp(-max(edgeDist - barDepth, 0.0) * 28.0) * val;

            // Thin gap between adjacent bars for definition.
            float cellFrac = fract(perimFrac * 128.0);
            float gap = smoothstep(0.0, 0.06, cellFrac) * smoothstep(1.0, 0.94, cellFrac);

            // Colour: warm gradient from bass to treble.
            float3 bassCol   = float3(1.0, 0.15, 0.05);
            float3 midCol    = float3(0.1, 0.9, 0.4);
            float3 trebleCol = float3(0.05, 0.5, 1.0);
            float t = perimFrac;
            float3 barCol;
            if (t < 0.5) {
                barCol = mix(bassCol, midCol, t * 2.0);
            } else {
                barCol = mix(midCol, trebleCol, (t - 0.5) * 2.0);
            }

            // Beat pulse brightens the whole frame.
            float beat = s.envelope;
            barCol *= 1.0 + beat * 0.8;

            float3 col = barCol * (barMask * gap * (0.7 + val * 1.5)
                                   + glowMask * 0.5);

            // Fade at the corners where two edges meet to avoid harsh seams.
            float cornerFade = smoothstep(0.0, 0.04, min(along, 1.0 - along));
            col *= cornerFade;

            return float4(themeGrade(col, u) * u.dim, 1.0);
        }
        """
    }
}
