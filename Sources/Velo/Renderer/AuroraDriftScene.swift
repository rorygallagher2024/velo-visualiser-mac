import Foundation

/// "Aurora Drift" — ported from Android.
///
/// Sweeping curtains of light built from fractional Brownian motion, over a
/// parallax starfield that twinkles to the highs. Bass drives the height and
/// the vertical surge, mids shift the palette, highs work the stars.
///
/// The first scene here that is generative rather than an instrument: nothing
/// in it reads as a measurement, so the audio arrives as four smoothed scalars
/// instead of a spectrum. Android takes those from its own band splits; here
/// they come from the shared `BandEnergy` fold over the same 31 bands the
/// analyser uses, which keeps every scene agreeing about what counts as bass.
final class AuroraDriftScene: VeloScene {

    let name = "Aurora Drift"

    private var energy = BandEnergy()

    func update(audio: AudioEngine, dt: Float) {
        energy.update(bands: audio.currentBands(), dt: dt)
    }

    func writeData(into pointer: UnsafeMutableRawPointer) {
        var packed = SIMD4<Float>(energy.low, energy.mid, energy.high, energy.envelope)
        pointer.copyMemory(from: &packed, byteCount: MemoryLayout<SIMD4<Float>>.size)
    }

    var shaderSource: String {
        """
        \(Self.shaderPreamble)

        struct Audio { float bass; float mid; float high; float env; };

        \(Self.fullscreenVertexShader)

        // Hash without sine — sin() based hashes band differently on every GPU.
        static inline float hash12(float2 p) {
            float3 p3 = fract(float3(p.x, p.y, p.x) * 0.1031);
            p3 += dot(p3, p3.yzx + 33.33);
            return fract((p3.x + p3.y) * p3.z);
        }

        static inline float valueNoise(float2 p) {
            float2 i = floor(p);
            float2 f = fract(p);
            float2 u = f * f * (3.0 - 2.0 * f);
            return mix(mix(hash12(i + float2(0.0, 0.0)), hash12(i + float2(1.0, 0.0)), u.x),
                       mix(hash12(i + float2(0.0, 1.0)), hash12(i + float2(1.0, 1.0)), u.x), u.y);
        }

        static inline float fbm(float2 p) {
            float v = 0.0;
            float a = 0.5;
            float2 shift = float2(100.0);
            float2x2 rot = float2x2(cos(0.5), sin(0.5), -sin(0.5), cos(0.5));
            for (int i = 0; i < 5; ++i) {
                v += a * valueNoise(p);
                p = rot * p * 2.0 + shift;
                a *= 0.5;
            }
            return v;
        }

        static inline float3 auroraColor(float t, float mid) {
            float offset = mid * 0.7;
            float3 a = float3(0.3, 0.5, 0.5);
            float3 b = float3(0.5, 0.5, 0.5);
            float3 c = float3(1.0, 1.0, 1.0);
            float3 d = float3(0.2, 0.40, 0.50) + float3(0.0, offset * 0.5, offset);
            return a + b * cos(6.28318 * (c * t + d));
        }

        fragment float4 veloFragment(VSOut in [[stage_in]],
                                     constant Uniforms &u [[buffer(0)]],
                                     constant Audio &s [[buffer(1)]])
        {
            float aspect = u.resolution.x / max(u.resolution.y, 1.0);
            // Origin bottom-left: the aurora hangs from the top of the sky and
            // the ground glow sits under it.
            float2 uv = float2(in.position.x, u.resolution.y - in.position.y) / u.resolution;
            uv.x *= aspect;

            float3 col = float3(0.0);

            // Starfield: a dense hash grid, of which only the brightest points
            // are ever drawn.
            float starVal = hash12(uv * 200.0);
            if (starVal > 0.993) {
                float twinkle = sin(u.time * 3.0 + starVal * 100.0) * 0.5 + 0.5;
                col += float3(1.0) * twinkle * (0.5 + s.high * 1.5);
            } else if (starVal > 0.985) {
                col += float3(0.6) * (0.2 + s.high * 0.5);
            }

            float2 p = uv;
            p.x += u.time * 0.02;                       // slow horizontal drift

            float auroraHeight = 0.35 + s.bass * 0.5 + s.env * 0.4;
            float3 aurora = float3(0.0);

            for (float i = 0.0; i < 3.0; i += 1.0) {
                float2 q = p * (1.0 + i * 0.3);
                q.y += u.time * 0.05;

                float n = fbm(q + float2(u.time * 0.02 * (i + 1.0), 0.0));

                // The curtain arcs across the sky, faded top and bottom.
                float shape = smoothstep(0.0, auroraHeight, uv.y + n * 0.5 - 0.2);
                shape *= smoothstep(auroraHeight + 0.4, auroraHeight - 0.2, uv.y + n * 0.5);

                // Vertical streaks, standing in for atmospheric collision.
                float streak = smoothstep(0.3, 0.7, valueNoise(float2(q.x * 8.0, q.y * 0.05)));

                float intensity = shape * (0.3 + streak * 0.5) * (1.0 - i * 0.25);
                aurora += auroraColor(n + i * 0.15 + u.time * 0.02, s.mid) * intensity;
            }

            // Constrained deliberately: unbounded gain here washes the curtains
            // out to a flat sheet on every loud passage.
            aurora *= (1.0 + s.bass * 1.2 + s.env * 0.8);
            col += aurora;

            // Deep blue ground glow.
            col += float3(0.0, 0.05, 0.15) * (1.0 - uv.y) * (1.0 + s.bass * 0.5);

            return float4(col * u.dim, 1.0);
        }
        """
    }
}
