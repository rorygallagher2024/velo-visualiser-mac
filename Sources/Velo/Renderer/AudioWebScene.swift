import Foundation
import Metal

/// "Audio Web" — ported from Android.
///
/// Eighty points drift and bounce in a box. Pairs closer than a threshold
/// are joined by a line whose brightness fades with distance. Bass speeds
/// the points, mids brighten the connections, highs flare the dots.
///
/// The CPU simulates the points and finds connections every frame, writing
/// line segments and point centres into a shared buffer. The vertex shader
/// expands each line into a thin quad and each point into a small glow
/// quad, all from `vertex_id` alone — no vertex buffer, just one flat
/// read from the history buffer.
final class AudioWebScene: VeloScene {

    let name = "Audio Web"

    private static let pointCount = 80
    private static let maxDist: Float = 0.35

    private var energy = BandEnergy()

    private var px = [Float](repeating: 0, count: pointCount)
    private var py = [Float](repeating: 0, count: pointCount)
    private var vx = [Float](repeating: 0, count: pointCount)
    private var vy = [Float](repeating: 0, count: pointCount)

    private var lineCount: Int = 0
    private var vertexCount: Int = 0
    private var buffer: MTLBuffer?

    var draw: SceneDraw {
        SceneDraw(primitive: .triangle, vertexCount: vertexCount, additive: true)
    }

    var historyBuffer: MTLBuffer? { buffer }

    init() {
        for i in 0..<Self.pointCount {
            px[i] = Float.random(in: -1...1)
            py[i] = Float.random(in: -1...1)
            vx[i] = Float.random(in: -0.1...0.1)
            vy[i] = Float.random(in: -0.1...0.1)
        }
    }

    func prepare(device: MTLDevice) {
        // Header 4 floats + max ~3160 lines × 5 floats + 80 points × 2 floats
        buffer = device.makeBuffer(length: 128 * 1024, options: .storageModeShared)
    }

    func update(audio: AudioEngine, dt: Float) {
        energy.update(bands: audio.currentBands(), dt: dt)

        let speedMult: Float = 1.0 + energy.low * 2.0

        for i in 0..<Self.pointCount {
            px[i] += vx[i] * dt * speedMult
            py[i] += vy[i] * dt * speedMult

            if px[i] < -1 || px[i] > 1 { vx[i] *= -1 }
            if py[i] < -1 || py[i] > 1 { vy[i] *= -1 }
            px[i] = max(-1, min(1, px[i]))
            py[i] = max(-1, min(1, py[i]))
        }

        guard let buf = buffer else { return }
        let ptr = buf.contents().bindMemory(to: Float.self,
                                             capacity: buf.length / MemoryLayout<Float>.stride)

        let maxDistSq = Self.maxDist * Self.maxDist
        var lc = 0
        let lineStart = 4

        for i in 0..<Self.pointCount {
            for j in (i + 1)..<Self.pointCount {
                let dx = px[i] - px[j]
                let dy = py[i] - py[j]
                let distSq = dx * dx + dy * dy
                if distSq < maxDistSq {
                    let alpha = 1.0 - sqrt(distSq) / Self.maxDist
                    let off = lineStart + lc * 5
                    ptr[off]     = px[i]
                    ptr[off + 1] = py[i]
                    ptr[off + 2] = px[j]
                    ptr[off + 3] = py[j]
                    ptr[off + 4] = alpha
                    lc += 1
                }
            }
        }
        lineCount = lc

        let pointStart = lineStart + lc * 5
        for i in 0..<Self.pointCount {
            ptr[pointStart + i * 2]     = px[i]
            ptr[pointStart + i * 2 + 1] = py[i]
        }

        ptr[0] = Float(lc)
        ptr[1] = 0
        ptr[2] = 0
        ptr[3] = 0

        vertexCount = lc * 6 + Self.pointCount * 6
        if vertexCount == 0 {
            print("[velo/web] WARNING: 0 vertices (buffer=\(buffer != nil), lines=\(lc))")
        }
    }

    func writeData(into pointer: UnsafeMutableRawPointer) {
        let beat = BeatBus.current.visualEnvelope
        var packed = SIMD4<Float>(energy.low, energy.mid, energy.high, beat)
        pointer.copyMemory(from: &packed, byteCount: MemoryLayout<SIMD4<Float>>.size)
    }

    var shaderSource: String {
        """
        \(Self.shaderPreamble)

        struct Web { float low; float mid; float high; float beat; };

        constant int POINTS = \(Self.pointCount);

        struct VSOut {
            float4 position [[position]];
            float3 color;
            float2 uv;
            float  isPoint;
        };

        constant float2 quadUV[6] = {
            float2(-1, -1), float2( 1, -1), float2(-1,  1),
            float2( 1, -1), float2( 1,  1), float2(-1,  1)
        };

        vertex VSOut veloVertex(uint vid [[vertex_id]],
                                constant Uniforms &u [[buffer(0)]],
                                constant Web &s [[buffer(1)]],
                                device const float *buf [[buffer(2)]])
        {
            float aspect = u.resolution.x / max(u.resolution.y, 1.0);
            int lineCount = int(buf[0]);
            int lineVerts = lineCount * 6;

            VSOut out;

            if (int(vid) < lineVerts) {
                // ---- line quad ----
                int lineIdx = int(vid) / 6;
                int corner  = int(vid) % 6;
                int base = 4 + lineIdx * 5;

                float2 a = float2(buf[base], buf[base + 1]);
                float2 b = float2(buf[base + 2], buf[base + 3]);
                float alpha = buf[base + 4];

                float2 dir = b - a;
                float len = length(dir);
                if (len < 1e-6) dir = float2(1, 0);
                else dir /= len;
                float2 perp = float2(-dir.y, dir.x);

                float halfW = (2.0 + s.mid * 4.0) / u.resolution.y;

                float2 uv = quadUV[corner];
                float2 p = mix(a, b, uv.x * 0.5 + 0.5) + perp * uv.y * halfW;

                out.position = float4(p.x / aspect, p.y, 0.0, 1.0);

                float3 lineCol = float3(0.2 + s.mid * 0.3,
                                        0.5 + s.mid * 0.5,
                                        0.8 + s.mid * 0.2);
                out.color = lineCol * alpha;
                out.uv = uv;
                out.isPoint = 0.0;

            } else {
                // ---- point quad ----
                int ptVid = int(vid) - lineVerts;
                int ptIdx = ptVid / 6;
                int corner = ptVid % 6;
                int base = 4 + lineCount * 5 + ptIdx * 2;

                float2 center = float2(buf[base], buf[base + 1]);
                float2 uv = quadUV[corner];

                float ptSize = (6.0 + s.high * 12.0) / u.resolution.y;
                float2 p = center + uv * ptSize;

                out.position = float4(p.x / aspect, p.y, 0.0, 1.0);
                out.color = float3(1.0);
                out.uv = uv;
                out.isPoint = 1.0;
            }

            return out;
        }

        fragment float4 veloFragment(VSOut in [[stage_in]],
                                     constant Uniforms &u [[buffer(0)]],
                                     constant Web &s [[buffer(1)]])
        {
            float3 c = in.color;

            if (in.isPoint > 0.5) {
                float d = length(in.uv);
                float glow = smoothstep(1.0, 0.2, d);
                c *= glow;
            } else {
                float edge = smoothstep(1.0, 0.5, abs(in.uv.y));
                c *= edge;
            }

            return float4(themeGrade(c, u) * u.dim, 0.0);
        }
        """
    }
}
