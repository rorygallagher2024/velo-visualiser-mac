import Foundation
import Metal

/// "Abyssal Drift" — Bioluminescent Fluid Filaments for DJ Stream Overlays.
///
/// Simulates deep-ocean bioluminescence: translucent undulating filaments,
/// drifting buoyant bell curves, and sparkling micro-plankton embers around
/// the perimeter of the frame. The central 60% is kept open for the camera feed.
///
/// Audio reactivity:
/// - Sub-bass / Kick: Sends glowing bioluminescent pulses surging down the filaments.
/// - Midrange: Modulates fluid buoyancy, drift velocity, and wave undulation.
/// - Treble / Hi-hats: Triggers sparkling micro-plankton embers in 3D parallax depth.
/// - Silence / Breakdowns: Drops to true black via BandGate.
final class AbyssalDriftScene: VeloScene {

    let name = "Abyssal Drift"

    private var gate = BandGate()

    private var fluidTime: Float = 0
    private var pulseWave: Float = 0
    private var planktonClock: Float = 0

    func update(audio: AudioEngine, dt: Float) {
        gate.update(bands: audio.currentBands(), dt: dt)

        let lowBass = gate.level[0]
        let midBass = gate.level[1]
        let mids = gate.level[2]
        let treble = gate.level[3]

        fluidTime += dt * (0.20 + mids * 0.50 + lowBass * 0.25)
        pulseWave += dt * (1.20 + lowBass * 3.50 + midBass * 1.80)
        planktonClock += dt * (0.40 + treble * 2.00)
    }

    func writeData(into pointer: UnsafeMutableRawPointer) {
        let p = pointer.bindMemory(to: Float.self, capacity: 8)
        p[0] = gate.level[0]   // lowBass
        p[1] = gate.level[1]   // midBass
        p[2] = gate.level[2]   // mids
        p[3] = gate.level[3]   // treble
        p[4] = gate.presence   // presence
        p[5] = fluidTime
        p[6] = pulseWave
        p[7] = planktonClock
    }

    var shaderSource: String {
        """
        \(Self.shaderPreamble)

        struct AbyssalData {
            float lowBass;
            float midBass;
            float mids;
            float treble;
            float presence;
            float fluidTime;
            float pulseWave;
            float planktonClock;
        };

        \(Self.fullscreenVertexShader)
        \(Self.rotation2D)

        static inline float hash11(float p) {
            p = fract(p * 0.1031);
            p *= p + 33.33;
            p *= p + p;
            return fract(p);
        }

        fragment float4 veloFragment(VSOut in [[stage_in]],
                                     constant Uniforms &u [[buffer(0)]],
                                     constant AbyssalData &s [[buffer(1)]])
        {
            if (s.presence < 0.001) {
                return float4(0.0);
            }

            float aspect = u.resolution.x / max(u.resolution.y, 1.0);
            float2 uv = float2(in.position.x, u.resolution.y - in.position.y) / u.resolution;
            float2 p = (uv - 0.5) * float2(aspect, 1.0);

            // Perimeter mask: keep center 60% clear
            float centerDist = length(p);
            float edgeMask = smoothstep(0.20, 0.70, centerDist);
            if (edgeMask < 0.001) {
                return float4(0.0);
            }

            float3 col = float3(0.0);

            // Palette: Bioluminescent Emerald / Cyan / Electric Violet
            float3 deepSeaCyan = float3(0.10, 0.85, 0.80);
            float3 bioEmerald  = float3(0.15, 1.00, 0.55);
            float3 abyssalBlue = float3(0.20, 0.40, 0.95);
            float3 pulseWhite  = float3(0.90, 0.98, 1.00);

            // 1. Undulating Bioluminescent Tentacle Filaments
            const int FILAMENTS = 6;
            for (int i = 0; i < FILAMENTS; i++) {
                float fi = float(i);
                float side = (i % 2 == 0 ? 1.0 : -1.0);
                float xOffset = side * (aspect * 0.5 - 0.08 - fi * 0.04);
                
                // Sinusoidal wave along Y
                float yPhase = p.y * 3.5 + s.fluidTime * (0.8 + fi * 0.2);
                float waveX = sin(yPhase) * 0.08 + cos(yPhase * 2.1 - s.fluidTime * 0.5) * 0.04;
                waveX *= (1.0 + s.mids * 0.8);

                float dx = abs(p.x - (xOffset + waveX));

                // Bioluminescent energy wave traveling down the filament
                float energyTravel = sin(p.y * 5.0 - s.pulseWave * 2.0 + fi * 1.5);
                float pulseIntensity = max(energyTravel, 0.0) * (0.6 + s.lowBass * 2.2);

                // Filament core and halo
                float core = exp(-dx * 450.0) * 1.5;
                float halo = exp(-dx * 45.0) * 0.25;

                float3 filamentCol = mix(deepSeaCyan, bioEmerald, hash11(fi + 3.0));
                col += (filamentCol * core + abyssalBlue * halo) * (0.7 + s.midBass * 0.6);
                col += pulseWhite * pulseIntensity * exp(-dx * 200.0);
            }

            // 2. Floating Bioluminescent Micro-Plankton Particles
            const int PLANKTON_COUNT = 24;
            for (int j = 0; j < PLANKTON_COUNT; j++) {
                float fj = float(j);
                float2 pos = float2(
                    (hash11(fj * 13.7) - 0.5) * aspect * 1.15,
                    (hash11(fj * 29.3) - 0.5) * 1.10
                );
                // Buoyancy drift
                pos.y += sin(s.fluidTime * 0.6 + fj * 1.8) * 0.15;
                pos.x += cos(s.fluidTime * 0.4 + fj * 2.3) * 0.15;

                float d = length(p - pos);
                float planktonRadius = 0.008 + hash11(fj * 7.1) * 0.012;

                float spark = exp(-pow(d / planktonRadius, 2.0) * 3.0);
                float twinkle = sin(s.planktonClock * 4.0 + fj * 5.0) * 0.5 + 0.5;

                float3 planktonCol = mix(bioEmerald, deepSeaCyan, hash11(fj + 11.0));
                col += planktonCol * spark * (0.4 + s.treble * 2.8 * twinkle);
            }

            col *= edgeMask * s.presence * (0.85 + s.lowBass * 0.5) * u.dim;

            float3 finalColor = themeGrade(col, u);
            return float4(finalColor, 1.0);
        }
        """
    }
}
