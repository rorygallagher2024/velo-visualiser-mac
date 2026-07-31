import Foundation
import Metal

/// "Spectral Canyon" — ported from Android.
///
/// A 3D wireframe landscape sculpted from the music's recent history. The
/// lateral axis is frequency (128 spectrum bins), the depth axis is time
/// (newest at the bottom, scrolling toward the horizon), and height is
/// magnitude. A curated colour ramp — deep indigo through cyan to magenta
/// to white-hot — maps height, so the loudest ridges burn bright while
/// valleys stay dark.
///
/// Each mesh row maps 1:1 to a history row. Data is sampled at the exact
/// row centre (no time interpolation) — once committed, a row's waveform
/// is static. Smooth scrolling is purely positional: the whole mesh slides
/// via `frac`, and when a commit fires, `head` advances by 1 while `frac`
/// drops by 1, so the visual appearance is continuous.
final class SpectralCanyonScene: VeloScene {

    static let bins = AudioEngine.binCount  // 128
    static let gridW = 100                  // mesh columns (frequency)
    static let gridD = 80                   // mesh rows (time depth)
    static let rows = gridD                 // history ring rows == mesh depth (1:1)

    let name = "Spectral Canyon"

    var draw: SceneDraw {
        let quads = (Self.gridW - 1) * (Self.gridD - 1)
        return SceneDraw(primitive: .triangle, vertexCount: quads * 6, additive: true)
    }

    private var scrollAccum: Float = 0
    private static let scrollRate: Float = 18.0
    private let maxCommits = 4
    private var head: Int = 0
    private var writeRow: Int = 0
    private var peakBuffer = [Float](repeating: 0, count: bins)
    private var energy = BandEnergy()
    private var history: MTLBuffer?

    var historyBuffer: MTLBuffer? { history }

    func prepare(device: MTLDevice) {
        history = device.makeBuffer(
            length: Self.rows * Self.bins * 2 * MemoryLayout<Float>.stride,
            options: .storageModeShared)
    }

    func update(audio: AudioEngine, dt: Float) {
        let binData = audio.currentBins()
        guard binData.count == Self.bins, let history else { return }

        energy.update(bands: audio.currentBands(), dt: dt)

        let peakDecay: Float = 1.0 - min(dt * 1.8, 1.0)
        for i in 0..<Self.bins {
            peakBuffer[i] = max(peakBuffer[i] * peakDecay, binData[i])
        }

        scrollAccum += dt * Self.scrollRate
        commitHistoryRows(binData: binData, history: history)
    }

    private func commitHistoryRows(binData: [Float], history: MTLBuffer) {
        guard scrollAccum >= 1 else { return }
        let stride = Self.bins * 2
        var commits = 0
        while scrollAccum >= 1 && commits < maxCommits {
            head = writeRow
            let dst = history.contents()
                .advanced(by: writeRow * stride * MemoryLayout<Float>.stride)
                .assumingMemoryBound(to: Float.self)
            for i in 0..<Self.bins {
                dst[i * 2] = binData[i]
                dst[i * 2 + 1] = peakBuffer[i]
            }
            writeRow = (writeRow + 1) % Self.rows
            scrollAccum -= 1
            commits += 1
        }
    }

    func writeData(into pointer: UnsafeMutableRawPointer) {
        let env = BeatBus.current.visualEnvelope
        var packed = SIMD4<Float>(Float(head), scrollAccum, energy.envelope, env)
        pointer.copyMemory(from: &packed, byteCount: MemoryLayout<SIMD4<Float>>.size)
    }

    var shaderSource: String {
        """
        \(Self.shaderPreamble)

        struct Canyon {
            float head;       // integer index of the newest committed row
            float frac;       // 0..1 smooth scroll between commits
            float energy;
            float beatEnv;
        };

        \(Self.glslMod)

        constant int BINS = \(Self.bins);
        constant int HIST_ROWS = \(Self.rows);
        constant int GRID_W = \(Self.gridW);
        constant int GRID_D = \(Self.gridD);

        // Sample one history row (no time interpolation — data is static per row).
        // Frequency axis interpolates across neighbouring bins.
        static inline float2 sampleRow(device const float *hist, int row, float fx) {
            float bx = fx * float(BINS - 1);
            int b0 = clamp(int(bx), 0, BINS - 1);
            int b1 = min(b0 + 1, BINS - 1);
            float fb = bx - float(b0);

            int base = row * BINS * 2;
            float2 s0 = float2(hist[base + b0 * 2], hist[base + b0 * 2 + 1]);
            float2 s1 = float2(hist[base + b1 * 2], hist[base + b1 * 2 + 1]);
            return mix(s0, s1, fb);
        }

        struct VSOut {
            float4 position [[position]];
            float  height;
            float  peak;
            float  fx;
            float  zt;
            float  gridU;
            float  gridV;
        };

        vertex VSOut veloVertex(uint vid [[vertex_id]],
                                constant Uniforms &u [[buffer(0)]],
                                constant Canyon &s [[buffer(1)]],
                                device const float *hist [[buffer(2)]])
        {
            int quadId = int(vid) / 6;
            int corner = int(vid) % 6;
            int cellRow = quadId / (GRID_W - 1);
            int cellCol = quadId % (GRID_W - 1);

            int dc = 0, dr = 0;
            switch (corner) {
                case 0: dc = 0; dr = 0; break;
                case 1: dc = 1; dr = 0; break;
                case 2: dc = 0; dr = 1; break;
                case 3: dc = 1; dr = 0; break;
                case 4: dc = 1; dr = 1; break;
                case 5: dc = 0; dr = 1; break;
            }
            int col = cellCol + dc;
            int row = cellRow + dr;

            float fx  = float(col) / float(GRID_W - 1);
            float zt0 = float(row) / float(GRID_D - 1);

            // Sample the FIXED history row for this mesh row (1:1 mapping,
            // no time interpolation — committed data is static).
            int headI = int(s.head);
            int histRow = headI - row;
            if (histRow < 0) histRow += HIST_ROWS;
            histRow = histRow % HIST_ROWS;

            float2 mp = sampleRow(hist, histRow, fx);
            float mag = mp.x;

            // Smooth scroll: shift the whole mesh back by the fractional
            // progress toward the next committed row (positional only).
            float zt = zt0 + s.frac / float(HIST_ROWS - 1);

            // Subtle camera drift.
            float bob  = sin(u.time * 0.15) * 0.025;
            float sway = sin(u.time * 0.11) * 0.016;
            float lean = sin(u.time * 0.08) * 0.12;

            // High-angle projection (matching Android).
            float xc = fx * 2.0 - 1.0;
            float persp = 1.0 / (1.0 + zt * (1.3 + lean));
            float px = xc * 0.96 * mix(1.0, 0.72, zt) + sway;
            float py = -0.9 + zt * 4.0 * persp + mag * 0.55 * persp + bob;

            VSOut out;
            out.position = float4(px, py, zt * 0.99, 1.0);
            out.height = mag;
            out.peak = mp.y;
            out.fx = fx;
            out.zt = zt;
            out.gridU = float(col);
            out.gridV = float(row);
            return out;
        }

        // Curated valley->peak gradient.
        static inline float3 terrainColor(float h) {
            float3 c = mix(float3(0.10, 0.05, 0.32), float3(0.05, 0.40, 0.85),
                           smoothstep(0.0, 0.22, h));
            c = mix(c, float3(0.00, 0.85, 0.90), smoothstep(0.18, 0.48, h));
            c = mix(c, float3(0.90, 0.20, 0.85), smoothstep(0.48, 0.78, h));
            c = mix(c, float3(1.30, 1.05, 1.35), smoothstep(0.82, 1.0, h));
            return c;
        }

        fragment float4 veloFragment(VSOut in [[stage_in]],
                                     constant Uniforms &u [[buffer(0)]],
                                     constant Canyon &s [[buffer(1)]])
        {
            float mag = in.height;
            float peak = in.peak;
            float fx = in.fx;
            float zt = in.zt;

            // Fade: emerge from black at bottom, dissolve toward horizon.
            float fade = smoothstep(0.0, 0.10, zt) * (1.0 - smoothstep(0.45, 0.82, zt));

            // Wireframe via screen-space derivatives of grid coords.
            float gu = fract(in.gridU);
            float gv = fract(in.gridV);
            float dwu = fwidth(in.gridU);
            float dwv = fwidth(in.gridV);
            float lineW = 1.2;
            float lineU = 1.0 - smoothstep(0.0, dwu * lineW, min(gu, 1.0 - gu));
            float lineV = 1.0 - smoothstep(0.0, dwv * lineW, min(gv, 1.0 - gv));
            float wire = max(lineU, lineV);

            // Colour: curated gradient with frequency tinting.
            float3 col = terrainColor(mag)
                       * mix(float3(1.10, 0.90, 1.00), float3(0.85, 1.00, 1.18), fx);
            col *= 0.45 + mag * 1.8;

            // Peak caps flare on the beat.
            float cap = smoothstep(0.18, 0.6, peak);
            col += float3(1.10, 1.15, 1.35) * cap * (0.6 + s.beatEnv * 2.0);

            col *= fade;
            col *= 1.5 + mag * 2.2;

            // Combine fill (dim, ridges only) and wireframe (full strength).
            float fillAlpha = 0.2 * smoothstep(0.0, 0.18, mag) * fade;
            float wireAlpha = wire * fade * (0.5 + mag * 1.5);
            float alpha = max(wireAlpha, fillAlpha);

            return float4(themeGrade(col, u) * alpha * u.dim, alpha);
        }
        """
    }
}
