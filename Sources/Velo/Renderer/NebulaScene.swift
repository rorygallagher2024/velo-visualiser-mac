import Foundation
import Metal

/// "Nebula" — an audio-reactive volumetric nebula with a starfield.
///
/// A raymarched volumetric scene: the camera flies through a procedural nebula
/// whose density, colour, and turbulence are driven by the audio's frequency
/// content. Bass swells the volume and shifts the palette toward deep reds and
/// golds, mids sculpt the medium-scale turbulence, and highs sparkle as point
/// stars in the foreground.
///
/// The nebula is built from layered 3D noise (fractional Brownian motion)
/// sampled along each ray. The noise field is distorted by time and audio
/// energy, creating organic flowing structures that breathe with the music.
///
/// The starfield is a separate pass: a hash-based point field whose density
/// and brightness respond to high-frequency energy, so cymbal hits scatter
/// bright stars across the frame.
final class NebulaScene: VeloScene {

    let name = "Nebula"

    private var energy = BandEnergy()

    func update(audio: AudioEngine, dt: Float) {
        energy.update(bands: audio.currentBands(), dt: dt)
    }

    func writeData(into pointer: UnsafeMutableRawPointer) {
        var data = SIMD4<Float>(energy.low, energy.mid, energy.high, energy.envelope)
        pointer.copyMemory(from: &data, byteCount: MemoryLayout<SIMD4<Float>>.stride)
    }

    var shaderSource: String {
        """
        \(Self.shaderPreamble)

        struct Energy { float4 bands; };  // x=low, y=mid, z=high, w=envelope

        \(Self.fullscreenVertexShader)

        // --- 2D Noise primitives ---
        // Fast, textureless 2D value noise.
        static inline float hash21(float2 p) {
            float3 p3 = fract(float3(p.xyx) * 0.1031);
            p3 += dot(p3, p3.yzx + 33.33);
            return fract((p3.x + p3.y) * p3.z);
        }

        static inline float noise(float2 p) {
            float2 i = floor(p);
            float2 f = fract(p);
            float2 u = f * f * (3.0 - 2.0 * f);
            return mix(mix(hash21(i + float2(0.0, 0.0)), hash21(i + float2(1.0, 0.0)), u.x),
                       mix(hash21(i + float2(0.0, 1.0)), hash21(i + float2(1.0, 1.0)), u.x), u.y);
        }

        // Fractional Brownian motion, 4 octaves.
        static inline float fbm(float2 p) {
            float v = 0.0;
            float a = 0.5;
            float2 shift = float2(100.0);
            // Rotate each octave to break grid alignment
            float2x2 rot = float2x2(0.8, -0.6, 0.6, 0.8);
            for (int i = 0; i < 4; ++i) {
                v += a * noise(p);
                p = rot * p * 2.0 + shift;
                a *= 0.5;
            }
            return v;
        }

        // --- Colour palette ---
        // Shifts smoothly with the audio energy.
        static inline float3 nebulaPalette(float t, float low, float mid, float hi) {
            float3 deep   = float3(0.08, 0.02, 0.16);   // dark violet
            float3 warm   = float3(0.75, 0.15, 0.10);   // crimson
            float3 bright = float3(0.95, 0.50, 0.15);   // amber
            float3 cool   = float3(0.15, 0.35, 0.85);   // blue

            float3 c = mix(deep, warm, smoothstep(0.0, 0.4, t + low * 0.2));
            c = mix(c, bright, smoothstep(0.3, 0.8, t) * (0.6 + low * 0.6));
            c = mix(c, cool, smoothstep(0.2, 0.7, t) * mid * 0.4);
            c += float3(0.6, 0.8, 1.0) * hi * 0.25 * smoothstep(0.6, 1.0, t);
            return c;
        }

        // --- Starfield ---
        static inline float3 stars(float2 uv, float hi, float time) {
            float3 col = float3(0.0);
            for (int layer = 0; layer < 2; layer++) {
                float scale = 60.0 + float(layer) * 120.0;
                float2 id = floor(uv * scale);
                float rnd = hash21(id + float(layer) * 137.0);
                if (rnd > 0.94) {
                    float2 gv = fract(uv * scale) - 0.5;
                    float2 offset = float2(hash21(id * 1.3) - 0.5,
                                           hash21(id * 2.7) - 0.5) * 0.7;
                    float d = length(gv - offset);
                    float brightness = 0.003 / (d * d + 0.001);
                    float twinkle = 0.6 + 0.4 * sin(time * (3.0 + rnd * 6.0) + rnd * 6.28);
                    brightness *= twinkle * (0.4 + hi * 1.5);
                    
                    float3 starCol = float3(0.9 + rnd * 0.1,
                                            0.85 + hash21(id * 3.1) * 0.15,
                                            0.95 + hash21(id * 4.7) * 0.05);
                    col += starCol * brightness;
                }
            }
            return col;
        }

        // --- Main fragment ---
        fragment float4 veloFragment(VSOut in [[stage_in]],
                                     constant Uniforms &u [[buffer(0)]],
                                     constant Energy &e [[buffer(1)]])
        {
            float aspect = u.resolution.x / max(u.resolution.y, 1.0);
            float2 uv = float2(in.position.x, u.resolution.y - in.position.y) / u.resolution;
            // Center UV and correct aspect
            float2 p = (uv - 0.5) * float2(aspect, 1.0);

            float low  = e.bands.x;
            float mid  = e.bands.y;
            float hi   = e.bands.z;
            float env  = e.bands.w;

            float time = u.time * 0.15;
            float3 col = float3(0.0);

            // --- Background Stars ---
            float2 starUV = p + float2(time * 0.05, 0.0); // slow pan
            col += stars(starUV, hi, u.time);

            // --- Domain Warped Nebula ---
            // An organic, flowing look produced by feeding noise into noise.
            // Bass swells the displacement distance; mids add fine turbulence.
            
            // Base coordinates with a slow zoom/pan
            float2 baseP = p * (2.0 - env * 0.3) + float2(time * 0.1, time * 0.05);
            
            // First warping layer
            float2 q;
            q.x = fbm(baseP + float2(0.0, 0.0) + time * 0.2);
            q.y = fbm(baseP + float2(5.2, 1.3) - time * 0.15);
            
            // Second warping layer
            float2 r;
            r.x = fbm(baseP + 4.0 * q + float2(1.7, 9.2) + time * 0.3);
            r.y = fbm(baseP + 4.0 * q + float2(8.3, 2.8) - time * 0.2);
            
            // Audio injects turbulence into the warp
            r += (mid * 0.15 + low * 0.2);

            // Final noise evaluation
            float n = fbm(baseP + 3.0 * r + time * 0.1);

            // Shape and density
            float density = smoothstep(0.1, 0.9, n * n);
            // Hollow out the dark areas
            density = density * density;
            
            // Color from the warped coordinate and noise value
            float colParam = n * 0.7 + r.x * 0.3;
            float3 nebulaCol = nebulaPalette(colParam, low, mid, hi);
            
            // Volumetric lighting approximation: darker where gradients are flat
            float lighting = 0.5 + 0.5 * smoothstep(0.0, 0.5, r.y);
            
            col += nebulaCol * density * lighting * (1.5 + env * 1.5);
            
            // --- Post-processing ---
            
            // Radial vignette
            float vignette = 1.0 - 0.7 * dot(p, p);
            col *= vignette;

            // Bloom
            float lum = dot(col, float3(0.2126, 0.7152, 0.0722));
            col += col * smoothstep(0.4, 1.2, lum) * 0.4;
            
            // Film grain
            float grain = hash21(uv + fract(u.time) * 10.0);
            col += (grain - 0.5) * (3.0 / 255.0);

            // Tone mapping
            col = col / (1.0 + col * 0.2);

            return float4(col * u.dim, 1.0);
        }
        """
    }
}
