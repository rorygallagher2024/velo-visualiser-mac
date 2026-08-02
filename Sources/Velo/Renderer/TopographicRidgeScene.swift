import Foundation
import Metal

/// "Topographic Ridge" — ported from Android.
///
/// A symmetric wireframe mountain range sculpted by the live spectrum. The
/// lateral axis is frequency (mirrored across the centre so it reads as a
/// designed ridge rather than a one-sided fan), the depth axis recedes toward
/// the horizon, and height is magnitude modulated by terrain noise. A deep
/// perspective from a low camera fills the frame with dramatic peaks.
///
/// On Android this is a VBO grid drawn with GL_LINES; on Metal the same
/// geometry is drawn as filled triangles with a screen-space wireframe effect
/// via `fwidth()` — the same technique Spectral Canyon uses.
final class TopographicRidgeScene: VeloScene {

    let name = "Topographic Ridge"

    private static let gridW = 96
    private static let gridD = 48
    private static let bins = AudioEngine.binCount

    var draw: SceneDraw {
        let quads = (Self.gridW - 1) * (Self.gridD - 1)
        return SceneDraw(primitive: .triangle, vertexCount: quads * 6, additive: true)
    }

    private var energy = BandEnergy()
    private var specBuffer = [Float](repeating: 0, count: AudioEngine.binCount)

    func update(audio: AudioEngine, dt: Float) {
        energy.update(bands: audio.currentBands(), dt: dt)
        let binData = audio.currentBins()
        guard binData.count == Self.bins else { return }
        let decay: Float = 1.0 - min(dt * 3.0, 1.0)
        for i in 0..<Self.bins {
            specBuffer[i] = max(specBuffer[i] * decay, binData[i])
        }
    }

    func writeData(into pointer: UnsafeMutableRawPointer) {
        let p = pointer.bindMemory(to: Float.self, capacity: 2 + Self.bins)
        p[0] = energy.envelope
        p[1] = energy.low
        for i in 0..<Self.bins {
            p[2 + i] = specBuffer[i]
        }
    }

    var shaderSource: String {
        """
        \(Self.shaderPreamble)

        struct RidgeData {
            float envelope;
            float bass;
            float spec[\(Self.bins)];
        };

        constant int GRID_W = \(Self.gridW);
        constant int GRID_D = \(Self.gridD);
        constant int BINS = \(Self.bins);

        static inline float hash11(float p) {
            float x = fract(p * 0.1031);
            x *= x + 33.33;
            x *= x + x;
            return fract(x);
        }

        static inline float vnoise(float2 p) {
            float2 i = floor(p), f = fract(p);
            f = f * f * (3.0 - 2.0 * f);
            float a = hash11(dot(i, float2(127.1, 311.7)));
            float b = hash11(dot(i + float2(1, 0), float2(127.1, 311.7)));
            float c = hash11(dot(i + float2(0, 1), float2(127.1, 311.7)));
            float d = hash11(dot(i + float2(1, 1), float2(127.1, 311.7)));
            return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
        }

        static inline float sampleSpec(constant RidgeData &s, float fx) {
            float bx = fx * float(BINS - 1);
            int b0 = clamp(int(bx), 0, BINS - 1);
            int b1 = min(b0 + 1, BINS - 1);
            float fb = bx - float(b0);
            float v = mix(s.spec[b0], s.spec[b1], fb);
            // Soft knee: mic range (<0.5) untouched, louder values compress.
            return v < 0.5 ? v : 0.5 + (v - 0.5) / (1.0 + (v - 0.5) * 2.0);
        }

        static inline float3 palette(float t) {
            return 0.5 + 0.5 * cos(6.28318 * (t + float3(0.0, 0.33, 0.67)));
        }

        struct VSOut {
            float4 position [[position]];
            float  height;
            float  gridU;
            float  gridV;
            float  fog;
        };

        vertex VSOut veloVertex(uint vid [[vertex_id]],
                                constant Uniforms &u [[buffer(0)]],
                                constant RidgeData &s [[buffer(1)]])
        {
            float aspect = u.resolution.x / max(u.resolution.y, 1.0);

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

            float x = float(col) / float(GRID_W - 1) * 2.0 - 1.0;
            float zt = float(row) / float(GRID_D - 1);
            float fx = abs(x);

            float spec = sampleSpec(s, fx);
            float terr = vnoise(float2(fx * 5.0, zt * 6.0 - u.time * 0.7));
            float h = spec * (0.45 + 0.55 * terr);
            h *= mix(1.0, 1.0 + spec * 2.0, fx);

            float depth = mix(1.0, 7.5, zt);
            float persp = 1.0 / depth;
            float px = (x * 2.1 * persp) / max(aspect, 1.0);
            float py = -0.30 + h * 1.8 * persp;

            VSOut out;
            out.position = float4(px, py, zt * 0.99, 1.0);
            out.height = h;
            out.fog = zt;
            out.gridU = float(col);
            out.gridV = float(row);
            return out;
        }

        fragment float4 veloFragment(VSOut in [[stage_in]],
                                     constant Uniforms &u [[buffer(0)]],
                                     constant RidgeData &s [[buffer(1)]])
        {
            float fade = pow(1.0 - in.fog, 1.6);
            float h = in.height;

            // Wireframe via screen-space derivatives.
            float gu = fract(in.gridU);
            float gv = fract(in.gridV);
            float dwu = fwidth(in.gridU);
            float dwv = fwidth(in.gridV);
            float lineW = 1.4;
            float lineU = 1.0 - smoothstep(0.0, dwu * lineW, min(gu, 1.0 - gu));
            float lineV = 1.0 - smoothstep(0.0, dwv * lineW, min(gv, 1.0 - gv));
            float wire = max(lineU, lineV);

            // Android colours: palette * brightness * fade * HDR lift.
            float3 col = palette(0.55 - h * 0.4);
            col *= (0.8 + h * 1.4);
            col *= fade;
            col *= 1.6 + h * 2.5;

            // Wire mask: full colour on the wire, discard between.
            col *= wire;

            return float4(themeGrade(col, u) * u.dim, 1.0);
        }
        """
    }
}
