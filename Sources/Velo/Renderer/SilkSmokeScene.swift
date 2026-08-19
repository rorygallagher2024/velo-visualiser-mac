import Foundation
import Metal

/// "Silk Smoke" — Fluid Curl-Noise Streamlines for DJ Overlays.
///
/// Continuous, ultra-smooth ribbons of weightless silk vapour drifting and
/// curling along the outer edges of the frame with soft Fresnel rim-lighting.
///
/// Audio reactivity:
/// - Sub-bass / Kick: Deepens vortex turbulence and swells outer smoke tendrils.
/// - Midrange: Modulates flow velocity and ribbon separation.
/// - Treble / Hi-hats: Weaves luminous, razor-thin filaments into smoke cores.
/// - Silence / Breakdowns: Fades cleanly to black via BandGate.
final class SilkSmokeScene: VeloScene {

    let name = "Silk Smoke"

    private var gate = BandGate()

    private var flowTime: Float = 0
    private var turbulence: Float = 0

    func update(audio: AudioEngine, dt: Float) {
        gate.update(bands: audio.currentBands(), dt: dt)

        let lowBass = gate.level[0]
        let midBass = gate.level[1]
        let mids = gate.level[2]
        let treble = gate.level[3]

        // Smoothly integrated flow velocity
        flowTime += dt * (0.20 + mids * 0.50 + lowBass * 0.30)
        turbulence += dt * (0.15 + lowBass * 0.80 + midBass * 0.40 + treble * 0.30)
    }

    func writeData(into pointer: UnsafeMutableRawPointer) {
        let p = pointer.bindMemory(to: Float.self, capacity: 7)
        p[0] = gate.level[0]   // lowBass
        p[1] = gate.level[1]   // midBass
        p[2] = gate.level[2]   // mids
        p[3] = gate.level[3]   // treble
        p[4] = gate.presence   // presence
        p[5] = flowTime
        p[6] = turbulence
    }

    var shaderSource: String {
        """
        \(Self.shaderPreamble)

        struct SmokeData {
            float lowBass;
            float midBass;
            float mids;
            float treble;
            float presence;
            float flowTime;
            float turbulence;
        };

        \(Self.fullscreenVertexShader)
        \(Self.rotation2D)

        static inline float hash21(float2 p) {
            return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453123);
        }

        static inline float noise(float2 p) {
            float2 i = floor(p);
            float2 f = fract(p);
            float2 u = f * f * (3.0 - 2.0 * f);
            return mix(mix(hash21(i + float2(0.0, 0.0)),
                           hash21(i + float2(1.0, 0.0)), u.x),
                       mix(hash21(i + float2(0.0, 1.0)),
                           hash21(i + float2(1.0, 1.0)), u.x), u.y);
        }

        static inline float fbm(float2 p) {
            float v = 0.0;
            float a = 0.5;
            float2 shift = float2(100.0);
            for (int i = 0; i < 4; ++i) {
                v += a * noise(p);
                p = p * 2.0 + shift;
                a *= 0.5;
            }
            return v;
        }

        fragment float4 veloFragment(VSOut in [[stage_in]],
                                     constant Uniforms &u [[buffer(0)]],
                                     constant SmokeData &s [[buffer(1)]])
        {
            if (s.presence < 0.001) {
                return float4(0.0);
            }

            float aspect = u.resolution.x / max(u.resolution.y, 1.0);
            float2 uv = float2(in.position.x, u.resolution.y - in.position.y) / u.resolution;
            float2 p = (uv - 0.5) * float2(aspect, 1.0);

            // Perimeter mask to keep the center open
            float centerDist = length(p);
            float edgeMask = smoothstep(0.20, 0.70, centerDist);
            if (edgeMask < 0.001) {
                return float4(0.0);
            }

            // Domain warping with curl-like flow fields
            float2 q = float2(
                fbm(p * 1.8 + float2(0.0, s.flowTime * 0.4)),
                fbm(p * 1.8 + float2(5.2, 1.3 - s.flowTime * 0.3))
            );

            float warpPower = 1.2 + s.lowBass * 1.4 + s.midBass * 0.6;
            float2 r = float2(
                fbm(p * 2.2 + 4.0 * q + float2(1.7, 9.2) + s.flowTime * 0.5),
                fbm(p * 2.2 + 4.0 * q + float2(8.3, 2.8) - s.flowTime * 0.4)
            ) * warpPower;

            float smokeField = fbm(p * 2.5 + 3.0 * r + s.turbulence * 0.2);

            // Razor-sharp core filament lines inside the smoke
            float filament1 = pow(max(1.0 - abs(sin(smokeField * 18.0 + s.flowTime * 2.0)), 0.0), 16.0);
            float filament2 = pow(max(1.0 - abs(cos(smokeField * 24.0 - s.flowTime * 1.5)), 0.0), 20.0);

            // Luxury Smoke Palette (Velvety Violet, Champagne Silk, Opal Cyan)
            float3 silkBase   = float3(0.18, 0.12, 0.35);
            float3 champagne  = float3(0.95, 0.85, 0.68);
            float3 opalCyan   = float3(0.30, 0.80, 0.95);

            float3 col = float3(0.0);
            col += silkBase * smoothstep(0.35, 0.85, smokeField) * 1.2;
            col += opalCyan * pow(smokeField, 3.5) * (0.8 + s.mids * 1.2);
            col += champagne * (filament1 + filament2) * (s.treble * 3.0 + 0.3);

            // Apply perimeter edge mask and presence
            col *= edgeMask * s.presence * (0.8 + s.lowBass * 0.7) * u.dim;

            float3 finalColor = themeGrade(col, u);
            return float4(finalColor, 1.0);
        }
        """
    }
}
