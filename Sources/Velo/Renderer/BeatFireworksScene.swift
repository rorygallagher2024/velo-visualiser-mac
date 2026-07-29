import Foundation
import Metal

/// "Beat Fireworks" — ported from Android.
///
/// Bass transients launch radial bursts of sparks over a field of quiet stars.
/// Each burst shares a hue, flies outward, arcs under gravity and fades. A
/// fixed particle pool with round-robin spawning, so a dense passage recycles
/// the oldest sparks rather than allocating.
///
/// The sparks genuinely integrate over time, so unlike the star field and the
/// bloom they cannot be derived from a vertex index — they need real per-particle
/// state. That rides in the scene's own buffer at index 2, written straight into
/// the memory the GPU reads. The background stars are the opposite case and are
/// hashed from their index in the shader, costing nothing at all.
final class BeatFireworksScene: VeloScene {

    let name = "Beat Fireworks"

    private static let maxSparks = 1600
    private static let stars = 150
    private static let capacity = maxSparks + stars

    /// Always the full pool. Spent sparks are pushed outside the clip volume in
    /// the vertex shader, where the GPU drops them before they cost a fragment,
    /// which is cheaper than varying the draw's vertex count every frame.
    let draw = SceneDraw.points(BeatFireworksScene.capacity)

    private let gravity: Float = 0.55
    private let drag: Float = 0.7
    private let maxLife: Float = 1.6
    private let burstRange = 50...90

    private var px = [Float](repeating: 0, count: maxSparks)
    private var py = [Float](repeating: 0, count: maxSparks)
    private var vx = [Float](repeating: 0, count: maxSparks)
    private var vy = [Float](repeating: 0, count: maxSparks)
    private var life = [Float](repeating: 0, count: maxSparks)
    private var hue = [Float](repeating: 0, count: maxSparks)
    private var cursor = 0

    private var energy = BandEnergy()
    private var clock: Float = 0
    private var lastBeatCount = 0
    private var rng = Rng(seed: 0xBEEF)

    private var particles: MTLBuffer?
    var historyBuffer: MTLBuffer? { particles }

    func prepare(device: MTLDevice) {
        // float4 per spark: x, y, life 0..1, hue.
        particles = device.makeBuffer(
            length: Self.maxSparks * 4 * MemoryLayout<Float>.stride,
            options: .storageModeShared)
    }

    func update(audio: AudioEngine, dt: Float) {
        energy.update(bands: audio.currentBands(), dt: dt)
        clock += dt

        let bus = BeatBus.current
        if bus.beatCount != lastBeatCount {
            lastBeatCount = bus.beatCount
            spawnBurst(energy: 0.85 + energy.low * 0.4)
        }

        integrate(dt: dt)
        publish()
    }

    /// Nothing rides in the shared buffer: the sparks are too large for it and
    /// live in this scene's own buffer instead.
    func writeData(into pointer: UnsafeMutableRawPointer) {}

    private func spawnBurst(energy: Float) {
        let cx = (rng.next() * 2 - 1) * 0.7
        let cy = (rng.next() * 2 - 1) * 0.6
        let h = rng.next()
        let count = burstRange.lowerBound
            + Int(rng.next() * Float(burstRange.count))
        let speed = 0.5 + energy * 0.7

        for _ in 0..<count {
            let i = cursor
            cursor = (cursor + 1) % Self.maxSparks
            let angle = rng.next() * 2 * .pi
            let sp = speed * (0.3 + rng.next() * 0.7)
            px[i] = cx
            py[i] = cy
            vx[i] = cos(angle) * sp
            vy[i] = sin(angle) * sp + 0.15      // a slight upward bias
            life[i] = maxLife * (0.6 + rng.next() * 0.4)
            hue[i] = h + (rng.next() - 0.5) * 0.1
        }
    }

    private func integrate(dt: Float) {
        for i in 0..<Self.maxSparks where life[i] > 0 {
            life[i] -= dt
            guard life[i] > 0 else { continue }
            vy[i] -= gravity * dt
            vx[i] -= vx[i] * drag * dt
            vy[i] -= vy[i] * drag * dt
            px[i] += vx[i] * dt
            py[i] += vy[i] * dt
        }
    }

    /// Pack the pool into the buffer the vertex shader reads.
    ///
    /// Written in place while earlier frames may still be reading it, the same
    /// trade the Spectrogram's history makes. A torn read costs one spark one
    /// frame of staleness, which is a fraction of a pixel of travel; the
    /// alternative is a per-frame copy of 25 KB to avoid an invisible artefact.
    private func publish() {
        guard let particles else { return }
        let p = particles.contents().bindMemory(
            to: Float.self, capacity: Self.maxSparks * 4)
        for i in 0..<Self.maxSparks {
            let o = i * 4
            p[o] = px[i]
            p[o + 1] = py[i]
            p[o + 2] = max(min(life[i] / maxLife, 1), 0)
            p[o + 3] = hue[i]
        }
    }

    var shaderSource: String {
        """
        \(Self.shaderPreamble)

        constant uint  SPARKS   = \(Self.maxSparks);
        constant float MAX_LIFE = 1.0;

        struct VSOut {
            float4 position [[position]];
            float  size     [[point_size]];
            float  life;
            float  hue;
        };

        static inline float3 hash31(float p) {
            float3 p3 = fract(float3(p) * float3(0.1031, 0.1030, 0.0973));
            p3 += dot(p3, p3.yzx + 33.33);
            return fract((p3.xxy + p3.yzz) * p3.zyx);
        }

        static inline float3 palette(float t) {
            return 0.5 + 0.5 * cos(6.28318 * (t + float3(0.0, 0.33, 0.67)));
        }

        vertex VSOut veloVertex(uint vid [[vertex_id]],
                                constant Uniforms &u [[buffer(0)]],
                                device const float4 *sparks [[buffer(2)]])
        {
            float aspect = u.resolution.x / max(u.resolution.y, 1.0);
            float dpi = max(u.resolution.y / 1080.0, 1.0);

            VSOut out;

            if (vid < SPARKS) {
                float4 d = sparks[vid];
                // Spent. Put it outside the clip volume so it is dropped before
                // it can cost a fragment.
                if (d.z <= 0.0) {
                    out.position = float4(1e6, 1e6, 0.0, 1.0);
                    out.size = 0.0;
                    out.life = 0.0;
                    out.hue = 0.0;
                    return out;
                }
                // Sparks fly in a square field, so the x axis is divided back
                // down and a burst stays circular on a wide canvas.
                out.position = float4(d.x / aspect, d.y, 0.0, 1.0);
                out.size = mix(1.5, 10.0, d.z) * dpi;
                out.life = d.z;
                out.hue = d.w;
                return out;
            }

            // Background stars: fixed positions with a slow twinkle, all of it
            // derived from the index. Nothing about them changes frame to frame
            // except the phase, so there is nothing to store.
            float3 h = hash31(float(vid) + 7.0);
            float3 g = hash31(float(vid) * 1.618 + 53.0);
            float freq = 0.3 + g.x * 1.2;
            float phase = g.y * 6.2831853;
            float base = 0.06 + g.z * 0.16;
            float twinkle = base * (1.0 + 0.6 * sin(u.time * freq * 6.2831853 + phase));

            out.position = float4(h.x * 2.0 - 1.0, h.y * 2.0 - 1.0, 0.0, 1.0);
            out.size = max(1.6 * dpi, 1.6);
            out.life = clamp(twinkle, 0.03, 0.30);
            out.hue = h.z;
            return out;
        }

        fragment float4 veloFragment(VSOut in [[stage_in]],
                                     float2 pc [[point_coord]],
                                     constant Uniforms &u [[buffer(0)]])
        {
            float2 c = pc * 2.0 - 1.0;
            float d = dot(c, c);
            if (d > 1.0) { discard_fragment(); }
            float glow = exp(-d * 2.5);
            // HDR: a fresh spark pushes well past 1.0 so the highlight blooms.
            float3 col = palette(in.hue) * in.life * glow * (1.0 + in.life * 1.5);
            return float4(col * u.dim, 1.0);
        }
        """
    }
}

/// A small deterministic generator.
///
/// Seeded rather than system random so a burst pattern reproduces between runs.
/// The self-test renders every scene twice, once with signal and once with
/// silence, and compares the two: an unseeded generator would make the sparks
/// differ for reasons that have nothing to do with the audio.
private struct Rng {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Float(state >> 40) / Float(1 << 24)
    }
}
