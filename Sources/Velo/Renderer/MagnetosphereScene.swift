import Foundation
import Metal

/// "Magnetosphere" — Toroidal Magnetic Dipole Flux for DJ Stream Overlays.
///
/// Luminous mathematical magnetic field lines arching in elegant 3D toroidal
/// curves between polar emitters across the frame. The magnetic geometry
/// naturally loops around the center, framing the DJ and mixer cleanly.
///
/// Audio reactivity:
/// - Sub-bass / Kick: Inflates the magnetic envelope and fires high-velocity plasma packets along the flux loops.
/// - Midrange: Precesses the 3D magnetic dipole axis with continuous angular drift.
/// - Treble / Hi-hats: Triggers magnetic reconnection micro-flashes at the cusp points.
/// - Silence / Breakdowns: Reverts to black via BandGate.
final class MagnetosphereScene: VeloScene {

    let name = "Magnetosphere"

    private var gate = BandGate()

    private var rotAngle: Float = 0
    private var fluxSpeed: Float = 0

    func update(audio: AudioEngine, dt: Float) {
        gate.update(bands: audio.currentBands(), dt: dt)

        let lowBass = gate.level[0]
        let midBass = gate.level[1]
        let mids = gate.level[2]
        let treble = gate.level[3]

        rotAngle += dt * (0.18 + mids * 0.45 + treble * 0.15)
        fluxSpeed += dt * (1.50 + lowBass * 3.80 + midBass * 2.00)
    }

    func writeData(into pointer: UnsafeMutableRawPointer) {
        let p = pointer.bindMemory(to: Float.self, capacity: 7)
        p[0] = gate.level[0]   // lowBass
        p[1] = gate.level[1]   // midBass
        p[2] = gate.level[2]   // mids
        p[3] = gate.level[3]   // treble
        p[4] = gate.presence   // presence
        p[5] = rotAngle
        p[6] = fluxSpeed
    }

    var shaderSource: String {
        """
        \(Self.shaderPreamble)

        struct MagnetoData {
            float lowBass;
            float midBass;
            float mids;
            float treble;
            float presence;
            float rotAngle;
            float fluxSpeed;
        };

        \(Self.fullscreenVertexShader)
        \(Self.rotation2D)

        static inline float3 rotateY(float3 p, float a) {
            float c = cos(a), s = sin(a);
            return float3(c * p.x + s * p.z, p.y, -s * p.x + c * p.z);
        }

        static inline float3 rotateX(float3 p, float a) {
            float c = cos(a), s = sin(a);
            return float3(p.x, c * p.y - s * p.z, s * p.y + c * p.z);
        }

        fragment float4 veloFragment(VSOut in [[stage_in]],
                                     constant Uniforms &u [[buffer(0)]],
                                     constant MagnetoData &s [[buffer(1)]])
        {
            if (s.presence < 0.001) {
                return float4(0.0);
            }

            float aspect = u.resolution.x / max(u.resolution.y, 1.0);
            float2 uv = float2(in.position.x, u.resolution.y - in.position.y) / u.resolution;
            float2 p = (uv - 0.5) * float2(aspect, 1.0);

            // Center mask: keep center 55% open
            float centerDist = length(p);
            float edgeMask = smoothstep(0.20, 0.60, centerDist);
            if (edgeMask < 0.001) {
                return float4(0.0);
            }

            // Palette: Aurora Blue, Plasma Purple, Solar Gold
            float3 plasmaCyan  = float3(0.20, 0.85, 1.00);
            float3 solarViolet = float3(0.85, 0.30, 0.95);
            float3 coreWhite   = float3(0.95, 0.98, 1.00);

            float3 col = float3(0.0);

            // Analytic Dipole Flux Lines in Screen Space
            const int LINES = 8;
            for (int i = 0; i < LINES; i++) {
                float fi = float(i);
                float side = (i % 2 == 0 ? 1.0 : -1.0);
                float R0 = 1.15 + (fi * 0.12) + s.lowBass * 0.25;

                // Rotated dipole coordinate
                float2 rotP = p;
                rotP = float2(
                    rotP.x * cos(s.rotAngle * 0.3 * side) - rotP.y * sin(s.rotAngle * 0.3 * side),
                    rotP.x * sin(s.rotAngle * 0.3 * side) + rotP.y * cos(s.rotAngle * 0.3 * side)
                );

                // Dipole field line equation: r = R0 * sin^2(theta)
                float r = length(rotP);
                float theta = atan2(rotP.y, rotP.x);
                float sinT = sin(theta);
                float idealR = R0 * (sinT * sinT) + 0.15;

                float dField = abs(r - idealR);

                // High-velocity plasma surge traveling along the flux line
                float plasmaPulse = sin(theta * 6.0 - s.fluxSpeed * 2.5 + fi * 0.8);
                float surgeGlow = max(plasmaPulse, 0.0) * exp(-dField * 120.0) * (0.8 + s.lowBass * 2.0);

                // Flux line filament core & halo
                float core = exp(-dField * 280.0) * 1.3;
                float halo = exp(-dField * 35.0) * 0.20;

                float3 lineCol = mix(plasmaCyan, solarViolet, fi / float(LINES));
                col += (lineCol * core + solarViolet * halo) * (0.6 + s.midBass * 0.8);
                col += coreWhite * surgeGlow;

                // Cusp reconnection micro-flash on treble
                float cusp = exp(-abs(rotP.y) * 40.0) * exp(-abs(rotP.x - 0.1) * 30.0);
                col += coreWhite * cusp * s.treble * 3.0;
            }

            col *= edgeMask * s.presence * (0.85 + s.lowBass * 0.5) * u.dim;

            float3 finalColor = themeGrade(col, u);
            return float4(finalColor, 1.0);
        }
        """
    }
}
