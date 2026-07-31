import Foundation

/// "Spectral Bloom" — ported from Android.
///
/// An eight-fold kaleidoscope over a domain-warped fractal flow. Bass pulses the
/// zoom and drives the radial rings, mids steer the drift rotation, highs
/// scatter shimmer through the centre.
///
/// The petal count is deliberately fixed. Android tried driving it from the mids
/// and it snapped between integers, which reads as a twitch rather than as
/// motion — a comment worth carrying over, because it is exactly the kind of
/// reactivity that seems like a good idea until it is on screen.
final class SpectralBloomScene: VeloScene {

    let name = "Spectral Bloom"

    private var energy = BandEnergy()

    init() {
        // ~0.25 s, slower than the default: this scene flows rather than snaps,
        // and a twitchy kaleidoscope is unwatchable.
        energy.smoothing = 4
    }

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

        struct Audio { float low; float mid; float high; float env; };

        \(Self.fullscreenVertexShader)
        \(Self.rotation2D)
        \(Self.glslMod)

        constant float TAU = 6.2831853;

        static inline float hash(float2 p) {
            p = fract(p * float2(123.34, 456.21));
            p += dot(p, p + 45.32);
            return fract(p.x * p.y);
        }

        static inline float valueNoise(float2 p) {
            float2 i = floor(p), f = fract(p);
            f = f * f * (3.0 - 2.0 * f);
            float a = hash(i),                  b = hash(i + float2(1.0, 0.0));
            float c = hash(i + float2(0.0, 1.0)), d = hash(i + float2(1.0, 1.0));
            return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
        }

        static inline float fbm(float2 p) {
            float s = 0.0, amp = 0.5;
            for (int i = 0; i < 4; i++) { s += amp * valueNoise(p); p *= 2.0; amp *= 0.5; }
            return s;
        }

        static inline float3 palette(float t) {
            return 0.5 + 0.5 * cos(TAU * (t + float3(0.0, 0.33, 0.67)));
        }

        fragment float4 veloFragment(VSOut in [[stage_in]],
                                     constant Uniforms &u [[buffer(0)]],
                                     constant Audio &s [[buffer(1)]])
        {
            // Shorter-axis normalisation: round and centred in any window shape.
            float2 fc = float2(in.position.x, u.resolution.y - in.position.y);
            float2 uv = (fc - 0.5 * u.resolution) / min(u.resolution.x, u.resolution.y);

            // Bass pulses the zoom; mids steer a slow drift rotation.
            uv *= 1.0 - s.low * 0.22;
            uv = rot2(u.time * 0.05 + s.mid * 0.6) * uv;

            float r = length(uv);
            float a = atan2(uv.y, uv.x);

            // Kaleidoscope mirror fold, FIXED petal count — see the note on the
            // Swift side about a mid-driven count snapping between integers.
            float sides = 8.0;
            float sector = TAU / sides;
            a = gmod(a, sector);
            a = abs(a - sector * 0.5);
            float2 p = float2(cos(a), sin(a)) * r;

            // Domain-warped fractal flow.
            float t = u.time * 0.3;
            float2 q = float2(fbm(p * 3.0 + t), fbm(p * 3.0 - t + 5.2));
            float f = fbm(p * 4.0 + q * 1.5 + float2(0.0, t));

            // Radial energy rings, driven harder by the bass.
            float rings = sin(r * 26.0 - u.time * 3.0 - s.low * 12.0) * 0.5 + 0.5;
            float v = f * 0.7 + rings * 0.3 * s.low;

            float3 col = palette(v + u.time * 0.05 + r * 0.3);
            col *= 0.6 + v * 1.4;                    // contrast
            col *= smoothstep(0.95, 0.1, r);         // vignette to black

            // Highs scatter shimmer across the centre.
            col += s.high * pow(max(1.0 - r, 0.0), 3.0) * 0.35;

            // Core flare on the bass, restrained so the centre does not blow out
            // to flat white.
            float core = exp(-r * 6.5);
            col += core * (0.22 + s.low * 0.7) * palette(u.time * 0.1 + 0.2);

            return float4(themeGrade(col, u) * u.dim, 1.0);
        }
        """
    }
}
