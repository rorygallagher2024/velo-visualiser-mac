import Foundation

/// "Beat Pulse" — ported from Android.
///
/// On every beat the central core slams open and an expanding shockwave ring
/// fires outward and fades. Bass energy fattens the core; the envelope
/// controls the bloom intensity. Up to eight rings travel simultaneously,
/// each launched at the moment its beat was detected.
///
/// Beat detection comes from the centralised `BeatBus` — the same signal
/// that will drive lighting and haptics.
final class BeatPulseScene: VeloScene {

    let name = "Beat Pulse"

    private var energy = BandEnergy()
    private var time: Float = 0

    private let maxRings = 8
    private var beats: [Float]
    private var head = 0
    private var lastBeatCount = 0

    init() {
        beats = Array(repeating: -1, count: maxRings)
    }

    func update(audio: AudioEngine, dt: Float) {
        energy.update(bands: audio.currentBands(), dt: dt)
        time += dt

        let bus = BeatBus.current
        if BeatBus.showBeatsOnVisuals, bus.beatCount != lastBeatCount {
            lastBeatCount = bus.beatCount
            beats[head] = time
            head = (head + 1) % maxRings
        } else {
            lastBeatCount = bus.beatCount
        }
    }

    func writeData(into pointer: UnsafeMutableRawPointer) {
        let p = pointer.bindMemory(to: Float.self, capacity: 2 + maxRings)
        p[0] = BeatBus.current.visualEnvelope
        p[1] = energy.low
        for i in 0..<maxRings { p[2 + i] = beats[i] }
    }

    var shaderSource: String {
        """
        \(Self.shaderPreamble)

        struct BeatData {
            float env;
            float low;
            float beats[8];
        };

        \(Self.fullscreenVertexShader)

        fragment float4 veloFragment(VSOut in [[stage_in]],
                                     constant Uniforms &u [[buffer(0)]],
                                     constant BeatData &s [[buffer(1)]])
        {
            constexpr float RING_LIFE  = 0.6;
            constexpr float RING_SPEED = 2.4;
            constexpr int   MAX_RINGS  = 8;

            float aspect = u.resolution.x / max(u.resolution.y, 1.0);
            float2 p = float2(in.position.x, u.resolution.y - in.position.y);
            float2 uv = p / u.resolution;
            float2 q = uv * 2.0 - 1.0;
            q.x *= aspect;
            float r = length(q);

            float3 col = float3(0.0);

            // Whole-screen flash on the beat.
            col += float3(0.09, 0.05, 0.02) * s.env;

            // Central core: slams open on the beat, with a soft halo.
            float coreR = 0.10 + s.env * 0.22 + s.low * 0.05;
            float core  = smoothstep(coreR, coreR - 0.05, r);
            float halo  = exp(-pow(r / (coreR + 0.18), 2.0) * 3.0);
            float3 warm = mix(float3(1.0, 0.45, 0.12), float3(1.0, 0.9, 0.7), s.env);
            col += warm * core * (1.6 + s.env * 8.0);
            col += warm * halo * (0.25 + s.env * 2.2);

            // Expanding shockwave rings — one per recent beat.
            for (int i = 0; i < MAX_RINGS; i++) {
                float bt = s.beats[i];
                if (bt < 0.0) continue;
                float age = u.time - bt;
                if (age < 0.0 || age > RING_LIFE) continue;
                float rad   = age * RING_SPEED;
                float width = 0.018 + age * 0.012;
                float ring  = exp(-pow((r - rad) / width, 2.0));
                float fade  = 1.0 - age / RING_LIFE;
                col += float3(1.0, 0.7, 0.4) * ring * fade * fade * 2.6;
            }

            return float4(themeGrade(col, u) * u.dim, 1.0);
        }
        """
    }
}
