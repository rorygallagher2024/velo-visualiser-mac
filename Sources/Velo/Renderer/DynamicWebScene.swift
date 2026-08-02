import CoreGraphics
import Foundation
import Metal

/// "Dynamic Web"
///
/// A more organic and reactive clone of "Audio Web". The dots and connections
/// respond dynamically to the frequency spectrum, shifting colors based on bass,
/// mids, and treble energy. The physics are gently influenced by the audio
/// to breathe naturally without becoming an aggressive strobe.
final class DynamicWebScene: VeloScene {

    let name = "Dynamic Web"

    private static let pointCount = 100
    private static let maxDist: Float = 0.35

    nonisolated(unsafe) static var colorEnabled: Bool = true

    private var energy = BandEnergy()

    // We'll also use ballistics for smooth color transitions, so it doesn't flicker instantly.
    private var colorBallistics: ColumnBallistics = {
        var b = ColumnBallistics(count: 3)
        b.attackRate = 12
        b.releaseRate = 3
        return b
    }()

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

    private static var screenAspect: Float {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        guard bounds.height > 0 else { return 16.0 / 9.0 }
        return max(Float(bounds.width / bounds.height), 1.0)
    }

    init() {
        for i in 0..<Self.pointCount {
            px[i] = Float.random(in: -2...2)
            py[i] = Float.random(in: -1...1)
            vx[i] = Float.random(in: -0.1...0.1)
            vy[i] = Float.random(in: -0.1...0.1)
        }
    }

    func prepare(device: MTLDevice) {
        buffer = device.makeBuffer(length: 128 * 1024, options: .storageModeShared)
    }

    func update(audio: AudioEngine, dt: Float) {
        energy.update(bands: audio.currentBands(), dt: dt)
        
        // Smooth out the color targets
        colorBallistics.update(
            targets: [energy.low, energy.mid, energy.high],
            dt: dt
        )

        let aspect = Self.screenAspect
        
        // Gentle, smoothed speed increase based on bass ballistics
        let speedMult: Float = 0.8 + colorBallistics.level[0] * 1.5

        for i in 0..<Self.pointCount {
            px[i] += vx[i] * dt * speedMult
            py[i] += vy[i] * dt * speedMult

            if px[i] < -aspect || px[i] > aspect { vx[i] *= -1 }
            if py[i] < -1 || py[i] > 1 { vy[i] *= -1 }
            px[i] = max(-aspect, min(aspect, px[i]))
            py[i] = max(-1, min(1, py[i]))
        }

        guard let buf = buffer else { return }
        let ptr = buf.contents().bindMemory(to: Float.self,
                                             capacity: buf.length / MemoryLayout<Float>.stride)

        let scaledMaxDist = Self.maxDist * sqrt(aspect)
        let maxDistSq = scaledMaxDist * scaledMaxDist
        var lc = 0
        let lineStart = 4

        for i in 0..<Self.pointCount {
            for j in (i + 1)..<Self.pointCount {
                let dx = px[i] - px[j]
                let dy = py[i] - py[j]
                let distSq = dx * dx + dy * dy
                if distSq < maxDistSq {
                    // Make connections fade out beautifully smoothly
                    let distRatio = sqrt(distSq) / scaledMaxDist
                    let t = max(0.0, min(1.0, distRatio))
                    let smooth = t * t * (3.0 - 2.0 * t)
                    let alpha = 1.0 - smooth
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
    }

    func writeData(into pointer: UnsafeMutableRawPointer) {
        let p = pointer.bindMemory(to: Float.self, capacity: 5)
        p[0] = colorBallistics.level[0] // Bass
        p[1] = colorBallistics.level[1] // Mids
        p[2] = colorBallistics.level[2] // Highs
        p[3] = energy.envelope          // Env
        p[4] = Self.colorEnabled ? 1.0 : 0.0 // Toggle
    }

    var shaderSource: String {
        """
        \(Self.shaderPreamble)

        struct Web { float bass; float mid; float high; float env; float colorEnabled; };

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
        
        // Define smoothstep locally to avoid unresolved identifier in Metal 2+
        static inline float smoothstep_custom(float edge0, float edge1, float x) {
            float t = clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
            return t * t * (3.0 - 2.0 * t);
        }

        vertex VSOut veloVertex(uint vid [[vertex_id]],
                                constant Uniforms &u [[buffer(0)]],
                                constant Web &s [[buffer(1)]],
                                device const float *buf [[buffer(2)]])
        {
            float aspect = u.resolution.x / max(u.resolution.y, 1.0);
            int lineCount = int(buf[0]);
            int lineVerts = lineCount * 6;

            VSOut out;

            // Base color depends on the mode
            float3 dynamicColor;
            
            if (s.colorEnabled > 0.5) {
                float3 baseColor = float3(0.15, 0.2, 0.25);
                float3 bassCol = float3(1.0, 0.15, 0.0); // Warm red/orange
                float3 midCol  = float3(0.0, 0.8, 0.4);  // Teal/green
                float3 highCol = float3(0.2, 0.4, 1.0);  // Cool blue
                
                float b = s.bass * 1.5;
                float m = s.mid * 1.5;
                float h = s.high * 1.5;
                
                float3 mixedCol = bassCol * b + midCol * m + highCol * h;
                
                // Force pure saturation by expanding the range so max is 1.0 and min is 0.0
                float cMax = max(mixedCol.r, max(mixedCol.g, mixedCol.b));
                float cMin = min(mixedCol.r, min(mixedCol.g, mixedCol.b));
                float delta = cMax - cMin;
                
                if (delta < 0.001) {
                    mixedCol = float3(0.0, 0.8, 1.0); // Fallback vibrant cyan
                } else {
                    mixedCol = (mixedCol - cMin) / delta;
                }
                
                // Now mixedCol is a PURE, vibrant color (at least one channel is 1.0, one is 0.0)
                // We mix this into the baseColor based on the overall volume of the track
                float totalEnergy = b + m + h;
                float intensity = clamp(totalEnergy * 0.4, 0.0, 1.0); // Reach full color quickly
                
                dynamicColor = mix(baseColor, mixedCol, intensity);
            } else {
                // Classic cool silver base for monochrome mode
                float3 baseColor = float3(0.6, 0.7, 0.8);
                float energySum = (s.bass + s.mid + s.high) * 0.4;
                dynamicColor = clamp(baseColor + float3(energySum), 0.0, 1.2);
            }

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

                // Mids thicken the lines smoothly
                float halfW = (1.5 + s.mid * 4.0) / u.resolution.y;

                float2 uv = quadUV[corner];
                float2 p = mix(a, b, uv.x * 0.5 + 0.5) + perp * uv.y * halfW;

                out.position = float4(p.x / aspect, p.y, 0.0, 1.0);

                out.color = dynamicColor * alpha * 0.7; // Lines are slightly dimmer than points
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

                // Treble increases dot size smoothly
                float ptSize = (5.0 + s.high * 15.0) / u.resolution.y;
                float2 p = center + uv * ptSize;

                out.position = float4(p.x / aspect, p.y, 0.0, 1.0);
                
                // Points are bright cores
                out.color = min(dynamicColor + float3(s.high * 0.3), float3(1.1)); 
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
                // Soft glow for points
                float glow = exp(-d * 3.5);
                c *= glow;
            } else {
                // Extremely soft edges for lines
                float edge = exp(-abs(in.uv.y) * 4.0);
                c *= edge;
            }
            
            // A subtle global breath
            c *= 1.0 + s.env * 0.2;

            if (s.colorEnabled > 0.5) {
                // Bypass global theme to preserve dynamic audio colors
                return float4(c * u.dim, 1.0);
            } else {
                // Apply global theme
                return float4(themeGrade(c, u) * u.dim, 1.0);
            }
        }
        """
    }
}
