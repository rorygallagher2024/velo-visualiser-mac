import Foundation
import Metal

/// "Prism Aura" — Anamorphic Lens Aberration & Flare Drift for DJ Overlays.
///
/// Simulates high-end optical lens phenomena: spectral rainbow fringing around
/// the edge of the lens, horizontal anamorphic streak flares on downbeats, and
/// floating optical bokeh motes that drift gently in foreground parallax.
///
/// Audio reactivity:
/// - Sub-bass / Kick: Expands chromatic dispersion radius and horizontal flare pulses.
/// - Midrange: Modulates optical streak brightness and angle.
/// - Treble / Hi-hats: Illuminates floating optical bokeh dust orbs.
/// - Silence / Breakdowns: Reverts cleanly to black via BandGate.
final class PrismAuraScene: VeloScene {

    let name = "Prism Aura"

    private var gate = BandGate()

    private var flareTime: Float = 0
    private var bokehTime: Float = 0

    func update(audio: AudioEngine, dt: Float) {
        gate.update(bands: audio.currentBands(), dt: dt)

        let lowBass = gate.level[0]
        let mids = gate.level[2]
        let treble = gate.level[3]

        flareTime += dt * (0.35 + lowBass * 1.20)
        bokehTime += dt * (0.15 + treble * 0.60 + mids * 0.25)
    }

    func writeData(into pointer: UnsafeMutableRawPointer) {
        let p = pointer.bindMemory(to: Float.self, capacity: 7)
        p[0] = gate.level[0]   // lowBass
        p[1] = gate.level[1]   // midBass
        p[2] = gate.level[2]   // mids
        p[3] = gate.level[3]   // treble
        p[4] = gate.presence   // presence
        p[5] = flareTime
        p[6] = bokehTime
    }

    var shaderSource: String {
        """
        \(Self.shaderPreamble)

        struct AuraData {
            float lowBass;
            float midBass;
            float mids;
            float treble;
            float presence;
            float flareTime;
            float bokehTime;
        };

        \(Self.fullscreenVertexShader)
        \(Self.rotation2D)

        static inline float hash11(float p) {
            p = fract(p * 0.1031);
            p *= p + 33.33;
            p *= p + p;
            return fract(p);
        }

        static inline float hash21(float2 p) {
            return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
        }

        fragment float4 veloFragment(VSOut in [[stage_in]],
                                     constant Uniforms &u [[buffer(0)]],
                                     constant AuraData &s [[buffer(1)]])
        {
            if (s.presence < 0.001) {
                return float4(0.0);
            }

            float aspect = u.resolution.x / max(u.resolution.y, 1.0);
            float2 uv = float2(in.position.x, u.resolution.y - in.position.y) / u.resolution;
            float2 p = (uv - 0.5) * float2(aspect, 1.0);

            float centerDist = length(p);
            float edgeMask = smoothstep(0.25, 0.75, centerDist);

            float3 col = float3(0.0);

            // 1. Spectral Chromatic Dispersion Edge Ring
            float dispersionRadius = 0.85 - s.lowBass * 0.15;
            float ringDist = abs(centerDist - dispersionRadius);
            
            // Separate R, G, B channels radially
            float rRing = exp(-pow(abs(centerDist - (dispersionRadius + 0.035)), 2.0) * 180.0);
            float gRing = exp(-pow(abs(centerDist - (dispersionRadius + 0.000)), 2.0) * 180.0);
            float bRing = exp(-pow(abs(centerDist - (dispersionRadius - 0.035)), 2.0) * 180.0);

            float3 spectralRing = float3(rRing * 1.1, gRing * 0.9, bRing * 1.3) * (0.6 + s.lowBass * 1.4);
            col += spectralRing * edgeMask;

            // 2. Anamorphic Horizontal Streak Flares (Cinema optics)
            for (int i = 0; i < 3; i++) {
                float fi = float(i);
                float yPos = (hash11(fi * 17.3) - 0.5) * 0.75;
                float flarePhase = fract(s.flareTime * (0.3 + fi * 0.15) + fi * 0.33);
                float flareX = mix(-aspect * 0.7, aspect * 0.7, flarePhase);
                
                float dy = abs(p.y - yPos);
                float dx = abs(p.x - flareX);

                // Anamorphic profile: ultra-narrow vertically, long horizontal streak
                float streak = exp(-dy * dy * 1200.0) * exp(-dx * dx * 1.8);
                float3 streakCol = mix(float3(0.3, 0.7, 1.0), float3(1.0, 0.4, 0.8), hash11(fi + 5.0));
                col += streakCol * streak * (s.lowBass * 2.2 + s.mids * 1.0) * edgeMask;
            }

            // 3. Floating Hexagonal Optical Bokeh Motes (Parallax dust)
            const int BOKEH_COUNT = 14;
            for (int j = 0; j < BOKEH_COUNT; j++) {
                float fj = float(j);
                float2 bPos = float2(
                    (hash11(fj * 23.1) - 0.5) * aspect * 1.2,
                    (hash11(fj * 37.7) - 0.5) * 1.1
                );
                // Drift upwards & sideways
                bPos.y += sin(s.bokehTime * 0.8 + fj * 1.4) * 0.2;
                bPos.x += cos(s.bokehTime * 0.5 + fj * 2.1) * 0.2;

                float distToBokeh = length(p - bPos);
                float bokehRadius = 0.04 + hash11(fj * 11.0) * 0.06;

                // Soft hexagonal optical disc
                float disc = smoothstep(bokehRadius, bokehRadius * 0.6, distToBokeh);
                float ring = exp(-pow(abs(distToBokeh - bokehRadius), 2.0) * 1400.0);

                float3 bokehCol = mix(float3(1.0, 0.85, 0.5), float3(0.4, 0.9, 1.0), hash11(fj * 7.3));
                float sparkle = sin(s.bokehTime * 3.0 + fj * 4.0) * 0.5 + 0.5;
                col += (bokehCol * disc * 0.3 + bokehCol * ring * 0.7) * (0.3 + s.treble * 2.0 * sparkle) * edgeMask;
            }

            col *= s.presence * (0.85 + s.lowBass * 0.5) * u.dim;

            float3 finalColor = themeGrade(col, u);
            return float4(finalColor, 1.0);
        }
        """
    }
}
