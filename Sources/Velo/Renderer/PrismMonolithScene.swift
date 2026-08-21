import Foundation
import Metal

/// "Prism Monolith" — Floating Crystalline Facets & TIR for DJ Overlays.
///
/// Geometric floating obsidian/quartz crystal polyhedral shards hovering in
/// the outer corners with simulated internal laser reflections and spectral
/// dispersion. The center of the screen is completely unobstructed.
///
/// Audio reactivity:
/// - Sub-bass / Kick: Expands crystal facet radius and surges internal resonance.
/// - Midrange: Drives continuous 3D tumbling rotation around multiple axes.
/// - Treble / Hi-hats: Triggers razor-sharp 4-point optical star diffraction flares.
/// - Silence / Breakdowns: Fades to black via BandGate.
final class PrismMonolithScene: VeloScene {

    let name = "Prism Monolith"

    private var gate = BandGate()

    private var rotX: Float = 0
    private var rotY: Float = 0
    private var rotZ: Float = 0
    private var resonanceClock: Float = 0

    func update(audio: AudioEngine, dt: Float) {
        gate.update(bands: audio.currentBands(), dt: dt)

        let lowBass = gate.level[0]
        let midBass = gate.level[1]
        let mids = gate.level[2]
        let treble = gate.level[3]

        rotX += dt * (0.20 + mids * 0.40 + midBass * 0.20)
        rotY += dt * (0.28 + mids * 0.50 + treble * 0.15)
        rotZ += dt * (0.15 + lowBass * 0.30)
        resonanceClock += dt * (1.0 + lowBass * 3.0)
    }

    func writeData(into pointer: UnsafeMutableRawPointer) {
        let p = pointer.bindMemory(to: Float.self, capacity: 8)
        p[0] = gate.level[0]   // lowBass
        p[1] = gate.level[1]   // midBass
        p[2] = gate.level[2]   // mids
        p[3] = gate.level[3]   // treble
        p[4] = gate.presence   // presence
        p[5] = rotX
        p[6] = rotY
        p[7] = rotZ
    }

    var shaderSource: String {
        """
        \(Self.shaderPreamble)

        struct MonolithData {
            float lowBass;
            float midBass;
            float mids;
            float treble;
            float presence;
            float rotX;
            float rotY;
            float rotZ;
        };

        \(Self.fullscreenVertexShader)
        \(Self.rotation2D)

        static inline float3 rotateX(float3 p, float a) {
            float c = cos(a), s = sin(a);
            return float3(p.x, c * p.y - s * p.z, s * p.y + c * p.z);
        }

        static inline float3 rotateY(float3 p, float a) {
            float c = cos(a), s = sin(a);
            return float3(c * p.x + s * p.z, p.y, -s * p.x + c * p.z);
        }

        static inline float3 rotateZ(float3 p, float a) {
            float c = cos(a), s = sin(a);
            return float3(c * p.x - s * p.y, s * p.x + c * p.y, p.z);
        }

        // Distance to a 3D regular octahedron crystal
        static inline float sdOctahedron(float3 p, float r) {
            p = abs(p);
            return (p.x + p.y + p.z - r) * 0.57735027;
        }

        fragment float4 veloFragment(VSOut in [[stage_in]],
                                     constant Uniforms &u [[buffer(0)]],
                                     constant MonolithData &s [[buffer(1)]])
        {
            if (s.presence < 0.001) {
                return float4(0.0);
            }

            float aspect = u.resolution.x / max(u.resolution.y, 1.0);
            float2 uv = float2(in.position.x, u.resolution.y - in.position.y) / u.resolution;
            float2 p = (uv - 0.5) * float2(aspect, 1.0);

            // Center mask: keep center 60% open
            float centerDist = length(p);
            float edgeMask = smoothstep(0.22, 0.65, centerDist);
            if (edgeMask < 0.001) {
                return float4(0.0);
            }

            float3 ro = float3(0.0, 0.0, 3.2);
            float3 rd = normalize(float3(p, -1.8));

            float3 col = float3(0.0);

            // Palette: Quartz Platinum, Diamond Cyan, Ruby Amber
            float3 platinum = float3(0.92, 0.95, 1.00);
            float3 cyanCore = float3(0.25, 0.85, 1.00);
            float3 amberHue = float3(1.00, 0.65, 0.30);

            // Render 4 floating corner crystal shards
            float crystalRadius = 0.45 + s.lowBass * 0.12;

            for (int i = 0; i < 4; i++) {
                float2 cornerPos = float2(
                    (i % 2 == 0 ? 1.0 : -1.0) * (aspect * 0.5 - 0.28),
                    (i / 2 == 0 ? 1.0 : -1.0) * 0.30
                );
                float3 crystalCenter = float3(cornerPos, -0.2);

                // Transform ray into crystal local frame
                float3 ro_l = ro - crystalCenter;
                float rotAngle = (i % 2 == 0 ? 1.0 : -1.0);
                ro_l = rotateZ(rotateY(rotateX(ro_l, s.rotX * rotAngle), s.rotY * rotAngle), s.rotZ * rotAngle);
                float3 rd_l = rotateZ(rotateY(rotateX(rd, s.rotX * rotAngle), s.rotY * rotAngle), s.rotZ * rotAngle);

                // Fast analytic raymarching for crystal wireframe & facets (18 steps)
                float t = 1.8;
                for (int step = 0; step < 18; step++) {
                    float3 pos = ro_l + rd_l * t;
                    float d = sdOctahedron(pos, crystalRadius);
                    if (d < 0.002) {
                        // Facet edge wire glow & Fresnel rim
                        float wireGlow = exp(-abs(d) * 350.0);
                        col += cyanCore * wireGlow * (0.8 + s.lowBass * 1.5);

                        // Vertex 4-point star flare
                        float vertexFlare = pow(max(1.0 - length(abs(pos) - float3(crystalRadius * 0.577)), 0.0), 12.0);
                        col += platinum * vertexFlare * (s.treble * 4.0 + 0.3);
                        break;
                    }
                    if (d > 1.2) { t += d * 0.8; }
                    else { t += max(d * 0.5, 0.02); }
                    if (t > 4.5) break;
                }
            }

            col *= edgeMask * s.presence * (0.85 + s.lowBass * 0.5) * u.dim;

            float3 finalColor = themeGrade(col, u);
            return float4(finalColor, 1.0);
        }
        """
    }
}
