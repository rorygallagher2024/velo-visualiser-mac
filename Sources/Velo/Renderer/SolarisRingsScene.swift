import Foundation
import Metal

/// "Solaris Rings" — Celestial Gyroscopic Armillary for DJ Stream Overlays.
///
/// Ultra-refined 3D celestial rings and orbital latitude/longitude arcs that
/// hover in perspective around the outer framing of the screen. The center
/// (50-60%) is deliberately kept clear of geometry to frame the DJ and decks.
///
/// Audio reactivity:
/// - Sub-bass / Kick: Expands the outer equatorial ring and surges luminous laser
///   energy pulses traveling along the orbital circumferences.
/// - Midrange: Drives continuous 3D gimbal rotation and orbital precession.
/// - Treble / Hi-hats: Sparks micro-constellation nodes and diffraction spikes at
///   ring intersections and coordinate ticks.
/// - Silence / Breakdowns: Gracefully recedes to zero luminescence via BandGate.
final class SolarisRingsScene: VeloScene {

    let name = "Solaris Rings"

    private var gate = BandGate()

    // Integrated rotation angles to avoid phase teleportation
    private var rotX: Float = 0
    private var rotY: Float = 0
    private var rotZ: Float = 0
    private var pulsePhase: Float = 0

    func update(audio: AudioEngine, dt: Float) {
        gate.update(bands: audio.currentBands(), dt: dt)

        let lowBass = gate.level[0]
        let midBass = gate.level[1]
        let mids = gate.level[2]
        let treble = gate.level[3]

        // Rotation speed accelerates with midrange and tempo energy
        rotX += dt * (0.15 + mids * 0.35 + midBass * 0.20)
        rotY += dt * (0.22 + mids * 0.45 + treble * 0.15)
        rotZ += dt * (0.10 + lowBass * 0.30)

        // Laser energy pulses around the rings
        pulsePhase += dt * (1.2 + lowBass * 3.5 + midBass * 2.0)
    }

    func writeData(into pointer: UnsafeMutableRawPointer) {
        let p = pointer.bindMemory(to: Float.self, capacity: 9)
        p[0] = gate.level[0]   // lowBass
        p[1] = gate.level[1]   // midBass
        p[2] = gate.level[2]   // mids
        p[3] = gate.level[3]   // treble
        p[4] = gate.presence   // presence
        p[5] = rotX
        p[6] = rotY
        p[7] = rotZ
        p[8] = pulsePhase
    }

    var shaderSource: String {
        """
        \(Self.shaderPreamble)

        struct SolarisData {
            float lowBass;
            float midBass;
            float mids;
            float treble;
            float presence;
            float rotX;
            float rotY;
            float rotZ;
            float pulse;
        };

        \(Self.fullscreenVertexShader)
        \(Self.rotation2D)

        // 3D rotation utilities
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

        // Distance to a 3D wire ring in the XY plane centered at origin
        static inline float sdRing(float3 p, float r, float thickness) {
            float2 q = float2(length(p.xy) - r, p.z);
            return length(q) - thickness;
        }

        fragment float4 veloFragment(VSOut in [[stage_in]],
                                     constant Uniforms &u [[buffer(0)]],
                                     constant SolarisData &s [[buffer(1)]])
        {
            // Early out on silence to keep OBS feed 100% clean
            if (s.presence < 0.001) {
                return float4(0.0);
            }

            float aspect = u.resolution.x / max(u.resolution.y, 1.0);
            float2 uv = float2(in.position.x, u.resolution.y - in.position.y) / u.resolution;
            float2 p = (uv - 0.5) * float2(aspect, 1.0);

            // Screen-space center clearance mask: smoothly fade out inner 45%
            float centerDist = length(p);
            float centerMask = smoothstep(0.22, 0.60, centerDist);
            if (centerMask < 0.001) {
                return float4(0.0);
            }

            // Ray setup from camera
            float3 ro = float3(0.0, 0.0, 3.4);
            float3 rd = normalize(float3(p, -1.8));

            // Dynamic ring radii modulated by bass
            float rOuter = 1.40 + s.lowBass * 0.16;
            float rMid   = 1.18 + s.midBass * 0.10;
            float rInner = 0.96 + s.mids * 0.08;

            // Palette definitions (Gold / Platinum / Cyan celestial aesthetics)
            float3 goldCol     = float3(1.00, 0.82, 0.45);
            float3 cyanCol     = float3(0.35, 0.85, 1.00);
            float3 platinumCol = float3(0.88, 0.92, 1.00);
            float3 laserCol    = float3(1.00, 0.35, 0.65);

            float3 accumColor = float3(0.0);

            // -------------------------------------------------------------
            // 1. EQUATORIAL OUTER RING (Analytic 3D projection)
            // -------------------------------------------------------------
            float tilt1 = 0.35 + sin(s.rotZ * 0.5) * 0.15;
            float spin1 = s.rotY * 0.6;
            // Transform ray to ring 1 local frame (inverse rotation)
            float3 ro1 = rotateY(rotateX(ro, -tilt1), -spin1);
            float3 rd1 = rotateY(rotateX(rd, -tilt1), -spin1);
            if (abs(rd1.z) > 0.001) {
                float t1 = -ro1.z / rd1.z;
                if (t1 > 0.5 && t1 < 6.0) {
                    float2 hit1 = ro1.xy + t1 * rd1.xy;
                    float dPlane1 = abs(length(hit1) - rOuter);
                    // Approximate 3D closest distance to wire
                    float d3D_1 = dPlane1 * max(abs(rd1.z), 0.25);
                    float angle1 = atan2(hit1.y, hit1.x);

                    float core1 = exp(-d3D_1 * 220.0) * 1.5;
                    float halo1 = exp(-d3D_1 * 35.0) * 0.35;
                    float pulse1 = sin(angle1 * 4.0 - s.pulse * 2.5);
                    float laser1 = exp(-d3D_1 * 120.0) * max(pulse1, 0.0) * (0.6 + s.lowBass * 2.2);
                    float notch1 = step(0.93, cos(angle1 * 36.0)) * exp(-d3D_1 * 150.0) * 0.8;
                    float spark1 = pow(max(cos(angle1 * 12.0), 0.0), 16.0) * s.treble * exp(-d3D_1 * 80.0) * 3.5;

                    accumColor += (platinumCol * core1 + goldCol * halo1) * (0.7 + s.presence * 0.6);
                    accumColor += laserCol * laser1 + goldCol * notch1 + float3(1.0, 0.95, 0.85) * spark1;
                }
            }

            // -------------------------------------------------------------
            // 2. GIMBAL MID RING (Analytic 3D projection)
            // -------------------------------------------------------------
            float tilt2 = 0.785 + s.rotX * 0.8;
            float spin2 = s.rotY;
            float yaw2  = s.rotZ * 0.5;
            float3 ro2 = rotateZ(rotateX(rotateY(ro, -spin2), -tilt2), -yaw2);
            float3 rd2 = rotateZ(rotateX(rotateY(rd, -spin2), -tilt2), -yaw2);
            if (abs(rd2.z) > 0.001) {
                float t2 = -ro2.z / rd2.z;
                if (t2 > 0.5 && t2 < 6.0) {
                    float2 hit2 = ro2.xy + t2 * rd2.xy;
                    float dPlane2 = abs(length(hit2) - rMid);
                    float d3D_2 = dPlane2 * max(abs(rd2.z), 0.25);
                    float angle2 = atan2(hit2.y, hit2.x);

                    float core2 = exp(-d3D_2 * 240.0) * 1.4;
                    float halo2 = exp(-d3D_2 * 35.0) * 0.30;
                    float pulse2 = sin(angle2 * 5.0 + s.pulse * 3.0);
                    float laser2 = exp(-d3D_2 * 130.0) * max(pulse2, 0.0) * (0.5 + s.midBass * 1.8);
                    float spark2 = pow(max(cos(angle2 * 8.0), 0.0), 16.0) * s.treble * exp(-d3D_2 * 80.0) * 2.8;

                    accumColor += (cyanCol * core2 + platinumCol * halo2 + cyanCol * laser2) * (0.6 + s.midBass * 0.8);
                    accumColor += float3(1.0, 0.95, 0.85) * spark2;
                }
            }

            // -------------------------------------------------------------
            // 3. INNER ASTROLABE RING (Analytic 3D projection)
            // -------------------------------------------------------------
            float tilt3 = -0.65 + s.rotX * 1.1;
            float yaw3  = -s.rotZ * 0.9;
            float spin3 = s.rotY * 1.2;
            float3 ro3 = rotateY(rotateZ(rotateX(ro, -tilt3), -yaw3), -spin3);
            float3 rd3 = rotateY(rotateZ(rotateX(rd, -tilt3), -yaw3), -spin3);
            if (abs(rd3.z) > 0.001) {
                float t3 = -ro3.z / rd3.z;
                if (t3 > 0.5 && t3 < 6.0) {
                    float2 hit3 = ro3.xy + t3 * rd3.xy;
                    float dPlane3 = abs(length(hit3) - rInner);
                    float d3D_3 = dPlane3 * max(abs(rd3.z), 0.25);

                    float core3 = exp(-d3D_3 * 260.0) * 1.3;
                    float halo3 = exp(-d3D_3 * 35.0) * 0.25;

                    accumColor += (goldCol * core3 + platinumCol * halo3) * (0.5 + s.mids * 0.9);
                }
            }

            // Apply center mask
            accumColor *= centerMask;

            // Optical anamorphic horizontal flare on transients
            float horizontalGlow = exp(-abs(p.y) * 140.0) * exp(-abs(p.x) * 2.5) * (s.lowBass * 0.6 + s.treble * 0.4);
            accumColor += laserCol * horizontalGlow * centerMask;

            // Overall energy scaling
            accumColor *= s.presence * u.dim;

            // Apply global theme color grade
            float3 finalColor = themeGrade(accumColor, u);
            return float4(finalColor, 1.0);
        }
        """
    }
}
