import Foundation
import Metal

/// "Plasma Storm" — ported from Android.
///
/// Tens of thousands of particles drifting through a divergence-free curl-noise
/// velocity field, drawn as additively-blended glowing point sprites. The cloud
/// forever swirls without pooling or tearing because the flow is curl of a
/// scalar potential — automatically divergence-free.
///
/// On Android this runs via ES 3.1 compute shaders; on Metal the CPU handles
/// the noise evaluation and particle integration (35k particles at one step per
/// frame is a few milliseconds on Apple Silicon) and the result rides a shared-
/// memory buffer the vertex shader reads directly, same pattern as
/// StrangeAttractor and BeatFireworks.
///
/// Audio drives the storm: bass surges the flow speed and, on kicks, blasts a
/// radial impulse outward from the centre; mids drift the palette; highs
/// sparkle; beats flare brightness.
final class PlasmaStormScene: VeloScene {

    let name = "Plasma Storm"

    private static let count = 35_000
    private static let life: Float = 7.0

    let draw = SceneDraw.points(PlasmaStormScene.count)

    private var energy = BandEnergy()
    private var speed: Float = 1
    private var clock: Float = 0
    private var rng = Rng(seed: 0xBEEF)

    private var particles: MTLBuffer?
    var historyBuffer: MTLBuffer? { particles }

    func prepare(device: MTLDevice) {
        let stride = Self.count * 4 * MemoryLayout<Float>.stride
        particles = device.makeBuffer(length: stride, options: .storageModeShared)
        guard let particles else { return }
        let p = particles.contents().bindMemory(to: Float.self, capacity: Self.count * 4)
        for i in 0..<Self.count {
            let o = i * 4
            p[o]     = rng.next() * 2.2 - 1.1
            p[o + 1] = rng.next() * 2.2 - 1.1
            p[o + 2] = rng.next() * Self.life
            p[o + 3] = 0
        }
    }

    func update(audio: AudioEngine, dt: Float) {
        energy.update(bands: audio.currentBands(), dt: dt)
        speed += ((1 + energy.low * 2.2) - speed) * 0.15
        clock += dt
        integrate(dt: dt)
    }

    func writeData(into pointer: UnsafeMutableRawPointer) {
        let p = pointer.bindMemory(to: Float.self, capacity: 4)
        p[0] = energy.mid
        p[1] = energy.high
        p[2] = energy.envelope
        p[3] = energy.low
    }

    // MARK: - CPU curl-noise integration

    private func hashV(_ x: Float, _ y: Float) -> Float {
        let v = sin(x * 127.1 + y * 311.7) * 43758.5453
        return v - floor(v)
    }

    private func vnoise(_ px: Float, _ py: Float) -> Float {
        let ix = floor(px), iy = floor(py)
        let fx = px - ix, fy = py - iy
        let ux = fx * fx * (3 - 2 * fx)
        let uy = fy * fy * (3 - 2 * fy)
        let a = hashV(ix, iy)
        let b = hashV(ix + 1, iy)
        let c = hashV(ix, iy + 1)
        let d = hashV(ix + 1, iy + 1)
        return a + (b - a) * ux + (c - a) * uy + (a - b - c + d) * ux * uy
    }

    private func curl(_ px: Float, _ py: Float) -> (Float, Float) {
        let e: Float = 0.08
        let nx1 = vnoise(px, py + e)
        let nx2 = vnoise(px, py - e)
        let ny1 = vnoise(px + e, py)
        let ny2 = vnoise(px - e, py)
        let inv: Float = 1.0 / (2.0 * e)
        return ((nx1 - nx2) * inv, -(ny1 - ny2) * inv)
    }

    private func hash11(_ p: Float) -> Float {
        var x = (p * 0.1031).truncatingRemainder(dividingBy: 1)
        if x < 0 { x += 1 }
        x *= x + 33.33
        x *= x + x
        return x.truncatingRemainder(dividingBy: 1)
    }

    private func integrate(dt: Float) {
        guard let particles else { return }
        let p = particles.contents().bindMemory(to: Float.self, capacity: Self.count * 4)
        let beat = energy.envelope
        let noiseScale: Float = 2.6 + energy.mid * 1.5
        let time = clock
        let spd = speed

        for i in 0..<Self.count {
            let o = i * 4
            var x = p[o], y = p[o + 1], age = p[o + 2]

            let npx = x * noiseScale
            let npy = y * noiseScale + time * 0.05
            let (cx, cy) = curl(npx, npy)

            let r = sqrt(x * x + y * y) + 1e-4
            let vx = cx + (x / r) * beat * 0.9
            let vy = cy + (y / r) * beat * 0.9

            x += vx * dt * spd
            y += vy * dt * spd
            age += dt

            if age > Self.life || abs(x) > 1.15 || abs(y) > 1.15 {
                let s = Float(i) + time * 60.0
                x = hash11(s * 0.013) * 2.2 - 1.1
                y = hash11(s * 0.027 + 5.0) * 2.2 - 1.1
                age = hash11(s * 0.07 + 1.0) * 2.0
                p[o] = x; p[o + 1] = y; p[o + 2] = age; p[o + 3] = 0
                continue
            }

            p[o] = x; p[o + 1] = y; p[o + 2] = age
            p[o + 3] = sqrt(vx * vx + vy * vy)
        }
    }

    var shaderSource: String {
        """
        \(Self.shaderPreamble)

        struct StormData {
            float mid;
            float high;
            float envelope;
            float bass;
        };

        constant float LIFE = \(Self.life);

        struct VSOut {
            float4 position [[position]];
            float  size     [[point_size]];
            float  age;
            float  speed;
        };

        vertex VSOut veloVertex(uint vid [[vertex_id]],
                                constant Uniforms &u [[buffer(0)]],
                                constant StormData &s [[buffer(1)]],
                                device const float4 *parts [[buffer(2)]])
        {
            float dpi = max(u.resolution.y / 1080.0, 1.0);
            float4 d = parts[vid];
            VSOut out;
            out.position = float4(d.xy, 0.0, 1.0);
            float fast = clamp(d.w * 1.5, 0.0, 1.0);
            out.size = clamp(dpi * 3.0 * (0.6 + fast + s.bass * 1.2), 1.0, 12.0);
            out.age = d.z;
            out.speed = d.w;
            return out;
        }

        static inline float3 palette(float t) {
            return 0.5 + 0.5 * cos(6.28318 * (t + float3(0.0, 0.33, 0.67)));
        }

        fragment float4 veloFragment(VSOut in [[stage_in]],
                                     float2 pc [[point_coord]],
                                     constant Uniforms &u [[buffer(0)]],
                                     constant StormData &s [[buffer(1)]])
        {
            float2 c = pc * 2.0 - 1.0;
            float d2 = dot(c, c);
            if (d2 > 1.0) discard_fragment();
            float glow = exp(-d2 * 3.2);

            float fade = smoothstep(0.0, 0.6, in.age)
                       * (1.0 - smoothstep(LIFE - 1.2, LIFE, in.age));

            float3 col = palette(0.55 + in.speed * 0.6 + s.mid * 0.5
                                 + u.time * 0.02);
            float spark = s.high * 0.6
                        * step(0.85, fract(sin(in.age * 91.7) * 1000.0));
            col += spark;

            float bright = fade * (0.35 + s.envelope * 0.8) * glow;
            col *= bright * (1.0 + s.envelope * 1.6);
            col = themeGrade(col, u) * u.dim;

            return float4(col, 1.0);
        }
        """
    }
}

private struct Rng {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Float(state >> 40) / Float(1 << 24)
    }
}
