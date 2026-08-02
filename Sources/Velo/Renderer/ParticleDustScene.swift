import Foundation
import Metal

/// "Particle Dust"
///
/// A highly subtle, ambient overlay designed to sit on top of DJ footage.
/// It renders a procedural field of soft, glowing dust motes that gently drift
/// and vibrate to the music. 
///
/// - The center of the screen is softly masked to avoid obscuring the subject.
/// - Bass drives gentle waves of brightness.
/// - Mids and Highs drive the physical vibration/jitter of the dust.
final class ParticleDustScene: VeloScene {

    let name = "Particle Dust"

    private var ballistics: ColumnBallistics = {
        var b = ColumnBallistics(count: 3)
        b.attackRate = 20
        b.releaseRate = 8
        return b
    }()
    private var energy = BandEnergy()

    func prepare(device: MTLDevice) {}

    func update(audio: AudioEngine, dt: Float) {
        energy.update(bands: audio.currentBands(), dt: dt)
        ballistics.update(
            targets: [energy.low, energy.mid, energy.high],
            dt: dt
        )
    }

    func writeData(into pointer: UnsafeMutableRawPointer) {
        var state = SIMD3<Float>(
            ballistics.level[0],
            ballistics.level[1],
            ballistics.level[2]
        )
        pointer.copyMemory(from: &state, byteCount: MemoryLayout<SIMD3<Float>>.size)
    }

    var shaderSource: String {
        """
        \(Self.shaderPreamble)

        struct DustState { float3 energy; };

        \(Self.fullscreenVertexShader)
        \(Self.glslMod)

        // Standard hash for pseudo-random noise
        static inline float hash12(float2 p) {
            float3 p3  = fract(float3(p.xyx) * .1031);
            p3 += dot(p3, p3.yzx + 33.33);
            return fract((p3.x + p3.y) * p3.z);
        }

        static inline float2 hash22(float2 p) {
            float3 p3 = fract(float3(p.xyx) * float3(.1031, .1030, .0973));
            p3 += dot(p3, p3.yzx+33.33);
            return fract((p3.xx+p3.yz)*p3.zy);
        }

        static inline float3 hsv2rgb(float3 c) {
            float4 K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
            float3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
            return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
        }

        fragment float4 veloFragment(VSOut in [[stage_in]],
                                     constant Uniforms &u [[buffer(0)]],
                                     constant DustState &state [[buffer(1)]])
        {
            float3 energy = state.energy;
            float lowE = energy.x;
            float midE = energy.y;
            float highE = energy.z;
            
            // Normalize UV coordinates (-1 to 1 based on height)
            float2 uv = (in.position.xy - 0.5 * u.resolution.xy) / u.resolution.y;
            
            // Subtle slow drift
            float time = u.time * 0.1;
            
            // We use a cellular/grid approach to render thousands of particles procedurally.
            // Scale defines the density of the dust. Lower = fewer, larger particles.
            float scale = 5.0;
            float2 gridUV = (uv + float2(time, time * 0.5)) * scale;
            
            float2 gridId = floor(gridUV);
            float2 gridFract = fract(gridUV) - 0.5;
            
            float finalBrightness = 0.0;
            float3 finalColor = float3(0.0);
            
            // Check 3x3 surrounding cells for procedural particles
            for (int y = -1; y <= 1; y++) {
                for (int x = -1; x <= 1; x++) {
                    float2 offset = float2(x, y);
                    float2 cellId = gridId + offset;
                    
                    // Random properties for the particle in this cell
                    float2 randomOffset = hash22(cellId) - 0.5; // -0.5 to 0.5
                    float randomSize = hash12(cellId + 1.23);
                    float randomPhase = hash12(cellId + 4.56) * 6.28;
                    
                    // Determine the "band affinity" of this particle based on its physical location.
                    // By using a smooth spatial gradient instead of a random hash, we avoid the 
                    // "Christmas lights" effect. Instead, large, slow-moving zones of the screen 
                    // will be dedicated to bass, mids, or treble.
                    float bandAffinity = fract(sin(gridUV.x * 0.05) + cos(gridUV.y * 0.04) + (u.time * 0.02)); // 0.0 to 1.0
                    
                    float3 particleColor = float3(0.0);
                    float audioPulse = 0.0;
                    
                    if (bandAffinity < 0.33) {
                        // Bass particle zone
                        audioPulse = lowE;
                        float3 targetColor = mix(float3(1.0, 0.1, 0.1), float3(1.0, 0.5, 0.0), hash12(cellId));
                        particleColor = mix(float3(0.8), targetColor, smoothstep(0.2, 0.7, lowE));
                    } else if (bandAffinity < 0.66) {
                        // Mid particle zone
                        audioPulse = midE;
                        float3 targetColor = mix(float3(0.1, 1.0, 0.8), float3(0.1, 1.0, 0.2), hash12(cellId));
                        particleColor = mix(float3(0.8), targetColor, smoothstep(0.2, 0.7, midE));
                    } else {
                        // Treble particle zone
                        audioPulse = highE;
                        float3 targetColor = mix(float3(0.2, 0.4, 1.0), float3(1.0, 0.2, 1.0), hash12(cellId));
                        particleColor = mix(float3(0.8), targetColor, smoothstep(0.2, 0.7, highE));
                    }
                    
                    // Calculate distance to the particle
                    float2 p = gridFract - offset - randomOffset;
                    float dist = length(p);
                    
                    // Audio pulse expands the radius and incorporates a twinkling phase
                    audioPulse *= (sin(u.time * 10.0 + randomPhase) * 0.5 + 0.5);
                    
                    // Soft Gaussian-like dot. 
                    // Made smaller and more subtle per user request.
                    float rawRadius = -0.02 + randomSize * 0.03 + audioPulse * 0.05;
                    
                    float brightness = 0.0;
                    if (rawRadius > 0.0) {
                        // Smooth, glowing edge
                        brightness = smoothstep(rawRadius, 0.0, dist);
                        
                        // Gentle twinkling
                        float twinkle = sin(u.time * 2.0 + randomPhase) * 0.5 + 0.5;
                        brightness *= mix(0.5, 1.0, twinkle);
                    }
                    
                    // Additive accumulation
                    if (brightness > 0.0) {
                        finalBrightness += brightness;
                        finalColor += particleColor * brightness;
                    }
                }
            }
            
            // Audio-driven brightness (lows make the whole field gently swell)
            finalColor *= 1.0 + (lowE * 1.5);
            
            // Subtly dim the extreme edges for a vignette
            float distFromCenter = length(uv);
            float vignette = smoothstep(1.2, 0.5, distFromCenter);
            
            finalColor *= vignette;
            
            return float4(themeGrade(finalColor, u) * u.dim, 1.0);
        }
        """
    }
}
