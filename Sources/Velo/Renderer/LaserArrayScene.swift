import Foundation

/// "Laser Array" — ported from Android.
///
/// Fourteen beams sweeping out of a vanishing point, the way a rig full of
/// scanners looks through haze. Lows widen the beams and drive the strobe; mids
/// and highs feed the spin.
///
/// The spin angle is accumulated on the CPU rather than derived from the audio
/// each frame. Deriving it would make the array jump backwards whenever the
/// music got quieter, because the angle would follow the level instead of
/// integrating it.
///
/// The Android version carries two optimisations worth keeping, both of which
/// turn per-pixel loops into closed forms: the beam angle and palette are
/// constant along a whole ray, and the twenty-step radial accumulation is a
/// geometric series, so it collapses to two `exp` calls and one divide.
final class LaserArrayScene: VeloScene {

    let name = "Laser Array"

    private var low: Float = 0
    private var spin: Float = 0
    private var energy = BandEnergy()

    func update(audio: AudioEngine, dt: Float) {
        energy.update(bands: audio.currentBands(), dt: dt)
        low += (energy.low - low) * min(dt * 15, 1)
        // Integrated, never assigned: the array must not rewind when the mix
        // thins out.
        spin += (energy.mid * 0.8 + energy.high * 0.6) * dt
    }

    func writeData(into pointer: UnsafeMutableRawPointer) {
        var packed = SIMD2<Float>(low, spin)
        pointer.copyMemory(from: &packed, byteCount: MemoryLayout<SIMD2<Float>>.size)
    }

    var shaderSource: String {
        """
        \(Self.shaderPreamble)

        struct Audio { float low; float spin; };

        \(Self.fullscreenVertexShader)
        \(Self.rotation2D)

        static inline float3 palette(float t) {
            return 0.5 + 0.5 * cos(6.28318 * (t + float3(0.0, 0.33, 0.67)));
        }

        fragment float4 veloFragment(VSOut in [[stage_in]],
                                     constant Uniforms &u [[buffer(0)]],
                                     constant Audio &s [[buffer(1)]])
        {
            constexpr float BEAMS = 14.0;

            float aspect = u.resolution.x / max(u.resolution.y, 1.0);
            float2 p = float2(in.position.x, u.resolution.y - in.position.y);
            float2 uv = p / u.resolution - 0.5;
            uv.x *= aspect;

            float3 rd = normalize(float3(uv, 1.4));
            float2x2 R = rot2(u.time * 0.15 + s.spin);

            float width = mix(0.05, 0.5, s.low);      // lows widen the beams
            float opacity = 0.15 + s.low * 1.8;       // lows strobe

            // The ray starts on the axis, so its xy is just rd.xy * t — which
            // means the angle, the beam mask and the palette are all constant
            // along the entire ray and hoist straight out of the march.
            float invW2 = 1.0 / (width * width + 1e-6);
            float2 q0 = R * rd.xy;
            float ang = atan2(q0.y, q0.x);
            float seg = ang / 6.28318 * BEAMS;
            float d = abs(fract(seg) - 0.5) * 2.0;
            float beam = exp(-d * d * invW2);
            float3 pal = palette(ang * 0.15 + u.time * 0.05);
            float C = max(length(rd.xy) * 0.6, 1e-3);

            // Twenty steps of exp(-C * (0.2 + i * 0.24)) is a geometric series,
            // so the whole march is a * (1 - r^n) / (1 - r): two exps, one
            // divide, no loop at all.
            float sumRadial = exp(-C * 0.2) * (1.0 - exp(-C * 4.8)) / (1.0 - exp(-C * 0.24));

            float3 col = pal * beam * sumRadial * opacity * 0.10;

            // Flare at the vanishing point, kept restrained.
            float r0 = length(uv);
            col += float3(0.6, 0.8, 1.0) * exp(-r0 * 7.0) * (0.25 + s.low * 0.5);

            return float4(col * u.dim, 1.0);
        }
        """
    }
}
