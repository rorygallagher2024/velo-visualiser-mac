import Foundation
import Metal

/// "Strange Attractor" — ported from Android.
///
/// Tens of thousands of particles integrating the Aizawa chaotic attractor,
/// traced as additively-blended glowing point sprites under a slowly orbiting
/// camera. Each particle follows the same deterministic flow yet never repeats,
/// so the cloud forever sketches the attractor's ornate sculptural form.
///
/// On Android this runs via ES 3.1 compute shaders; on Metal the CPU handles
/// the integration (the Aizawa ODE is cheap — 50k particles at 6 sub-steps is
/// microseconds on Apple Silicon) and the result rides in a shared-memory
/// buffer the vertex shader reads directly, same pattern as BeatFireworks.
///
/// Audio nudges the flow, never the equation's stability: bass speeds the
/// integration (the form surges on kicks) and pulses the zoom; beats flare
/// brightness; mids drift the palette.
final class StrangeAttractorScene: VeloScene {

    let name = "Strange Attractor"

    private static let count = 50_000
    private static let floatsPerParticle = 4

    let draw = SceneDraw.points(StrangeAttractorScene.count)

    private var energy = BandEnergy()
    private var speed: Float = 1
    private var zoom: Float = 1.3
    private var clock: Float = 0
    private var rng = Rng(seed: 0xA17A)

    private var particles: MTLBuffer?
    var historyBuffer: MTLBuffer? { particles }

    func prepare(device: MTLDevice) {
        let stride = Self.count * Self.floatsPerParticle * MemoryLayout<Float>.stride
        particles = device.makeBuffer(length: stride, options: .storageModeShared)
        guard let particles else { return }
        let p = particles.contents().bindMemory(to: Float.self, capacity: Self.count * 4)
        for i in 0..<Self.count {
            let o = i * 4
            p[o]     = rng.next() * 0.4 - 0.2
            p[o + 1] = rng.next() * 0.4 - 0.2
            p[o + 2] = rng.next() * 0.4 - 0.2
            p[o + 3] = rng.next() * 6.0
        }
    }

    func update(audio: AudioEngine, dt: Float) {
        energy.update(bands: audio.currentBands(), dt: dt)
        speed += ((1 + energy.low * 1.6) - speed) * min(0.15 * 60 * dt, 1)
        zoom += ((1.3 + energy.low * 0.25) - zoom) * min(0.1 * 60 * dt, 1)
        clock += dt
        integrate(dt: dt)
    }

    func writeData(into pointer: UnsafeMutableRawPointer) {
        let p = pointer.bindMemory(to: Float.self, capacity: 3)
        p[0] = energy.mid
        p[1] = energy.envelope
        p[2] = zoom
    }

    private func integrate(dt: Float) {
        guard let particles else { return }
        let p = particles.contents().bindMemory(to: Float.self, capacity: Self.count * 4)
        let stepDt: Float = 0.006 * speed
        let time = clock

        for i in 0..<Self.count {
            let o = i * 4
            var x = p[o], y = p[o + 1], z = p[o + 2], age = p[o + 3]

            for _ in 0..<6 {
                let dx = (z - 0.7) * x - 3.5 * y
                let dy = 3.5 * x + (z - 0.7) * y
                let dz = 0.6 + 0.95 * z - (z * z * z) / 3.0
                     - (x * x + y * y) * (1.0 + 0.25 * z)
                     + 0.1 * z * (x * x * x)
                x += dx * stepDt
                y += dy * stepDt
                z += dz * stepDt
            }
            age += stepDt

            let r2 = x * x + y * y + z * z
            if age > 6 || r2 > 16 || r2.isNaN {
                let s = Float(i) + time
                x = hash(s * 0.013) * 0.2 - 0.1
                y = hash(s * 0.027 + 5) * 0.2 - 0.1
                z = hash(s * 0.041 + 9) * 0.2 - 0.1
                age = hash(s * 0.07 + 1) * 3.0
            }

            p[o] = x; p[o + 1] = y; p[o + 2] = z; p[o + 3] = age
        }
    }

    private func hash(_ p: Float) -> Float {
        var x = (p * 0.1031).truncatingRemainder(dividingBy: 1)
        if x < 0 { x += 1 }
        x *= x + 33.33
        x *= x + x
        return x.truncatingRemainder(dividingBy: 1)
    }

    var shaderSource: String {
        """
        \(Self.shaderPreamble)

        struct AttractorData {
            float mid;
            float envelope;
            float zoom;
        };

        constant uint COUNT = \(Self.count);

        struct VSOut {
            float4 position [[position]];
            float  size     [[point_size]];
            float  depth;
            float  age;
        };

        vertex VSOut veloVertex(uint vid [[vertex_id]],
                                constant Uniforms &u [[buffer(0)]],
                                constant AttractorData &s [[buffer(1)]],
                                device const float4 *parts [[buffer(2)]])
        {
            float aspect = u.resolution.x / max(u.resolution.y, 1.0);
            float dpi = max(u.resolution.y / 1080.0, 1.0);

            float4 d = parts[vid];
            VSOut out;

            if (d.w <= 0.0) {
                out.position = float4(1e6, 1e6, 0.0, 1.0);
                out.size = 0.0;
                out.depth = 0.0;
                out.age = 0.0;
                return out;
            }

            // Centre the attractor, then orbit (yaw about Y, pitch about X).
            float3 p = d.xyz - float3(0.0, 0.0, 0.6);
            float yaw = u.time * 0.16;
            float pitch = 0.42 + 0.14 * sin(u.time * 0.09);
            float cy = cos(yaw), sy = sin(yaw);
            p = float3(cy * p.x + sy * p.z, p.y, -sy * p.x + cy * p.z);
            float cx = cos(pitch), sx = sin(pitch);
            p = float3(p.x, cx * p.y - sx * p.z, sx * p.y + cx * p.z);

            float persp = 1.0 / (2.8 + p.z);
            float2 sp = p.xy * s.zoom * persp;
            sp.x /= aspect;
            out.position = float4(sp, 0.0, 1.0);
            out.size = clamp(dpi * 3.5 * persp * 2.8, 1.0, 9.0);
            out.depth = p.z;
            out.age = d.w;
            return out;
        }

        static inline float3 palette(float t) {
            return 0.5 + 0.5 * cos(6.28318 * (t + float3(0.0, 0.33, 0.67)));
        }

        fragment float4 veloFragment(VSOut in [[stage_in]],
                                     float2 pc [[point_coord]],
                                     constant Uniforms &u [[buffer(0)]],
                                     constant AttractorData &s [[buffer(1)]])
        {
            float2 c = pc * 2.0 - 1.0;
            float d2 = dot(c, c);
            if (d2 > 1.0) discard_fragment();
            float glow = exp(-d2 * 3.2);

            float ageF = clamp(1.2 - in.age * 0.12, 0.35, 1.2);
            float a = glow * ageF * (0.42 + s.envelope * 0.5);
            float3 col = palette(0.55 + in.depth * 0.22 + s.mid * 0.5 + u.time * 0.03);
            col *= a * (1.0 + ageF * 1.5);
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
