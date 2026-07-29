import Foundation
import Metal

/// "Ethereal Ribbons"
///
/// A premium, organic aurora-like visualizer.
/// Three distinct ribbons of light flow horizontally across the screen,
/// explicitly separating the audio frequencies (Bass, Mid, High).
/// The center is naturally left clear to frame DJ footage perfectly.
final class EtherealRibbonsScene: VeloScene {

    let name = "Ethereal Ribbons"

    private var ballistics: ColumnBallistics = {
        var b = ColumnBallistics(count: 3)
        b.attackRate = 25 // Fast attack
        b.releaseRate = 5 // Smooth, lingering release
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

        struct RibbonState { float3 energy; };

        \(Self.fullscreenVertexShader)
        \(Self.glslMod)

        // Function to generate a solid, organic ribbon
        static inline float renderRibbon(float2 uv, float time, float yOffset, float frequency, float baseAmplitude, float speed, float thickness, float energy, float phase) {
            
            // Energy heavily amplifies the physical height/swing of the ribbon
            float activeAmplitude = baseAmplitude + (energy * 0.15); 
            
            // Complex organic wave composed of multiple sines
            float y = sin(uv.x * frequency + time * speed + phase) * activeAmplitude;
            y += cos(uv.x * frequency * 1.6 - time * speed * 0.7 + phase * 1.5) * (activeAmplitude * 0.6);
            y += sin(uv.x * frequency * 2.5 + time * speed * 1.2) * (activeAmplitude * 0.3);
            
            // Audio-driven high-frequency turbulence
            y += sin(uv.x * 15.0 + time * 10.0) * (energy * 0.04);
            
            // Distance from pixel to the ribbon curve
            float dist = abs(uv.y - (yOffset + y));
            
            // The line slightly thickens when loud
            float currentThickness = thickness * (1.0 + energy * 1.5);
            
            // Crisp, anti-aliased line (no soft glow spreading outwards)
            float core = smoothstep(currentThickness + 0.003, currentThickness, dist);
            
            return core;
        }

        fragment float4 veloFragment(VSOut in [[stage_in]],
                                     constant Uniforms &u [[buffer(0)]],
                                     constant RibbonState &state [[buffer(1)]])
        {
            float lowE = state.energy.x;
            float midE = state.energy.y;
            float highE = state.energy.z;
            
            // Normalize UV coordinates (-aspect to aspect, -0.5 to 0.5)
            float2 uv = (in.position.xy - 0.5 * u.resolution.xy) / u.resolution.y;
            float time = u.time * 0.5;
            
            float3 finalColor = float3(0.0);
            
            // 1. Bass Ribbon (Flowing along the bottom)
            // Thick, slow, deep magenta/red. Billows heavily with low frequencies.
            float bassIntensity = renderRibbon(uv, time, 
                                               -0.35, // yOffset (bottom)
                                               1.5,   // frequency
                                               0.1,   // amplitude
                                               0.8,   // speed
                                               0.015, // thickness
                                               lowE,  // energy
                                               0.0);  // phase
            float3 bassColor = float3(1.0, 0.1, 0.3) * (0.5 + lowE * 1.5);
            finalColor += bassColor * bassIntensity;
            
            // 2. Mid Ribbon (Weaving just above the bass)
            // Medium thickness, moderate speed, cyan/green.
            float midIntensity = renderRibbon(uv, time, 
                                              -0.2,   // yOffset
                                              2.5,    // frequency
                                              0.08,   // amplitude
                                              1.2,    // speed
                                              0.008,  // thickness
                                              midE,   // energy
                                              2.0);   // phase
            float3 midColor = float3(0.1, 1.0, 0.6) * (0.5 + midE * 2.0);
            finalColor += midColor * midIntensity;
            
            // 3. Treble Ribbon (Flowing along the top)
            // Very thin, fast, sharp white/blue. Electric streaks.
            float highIntensity = renderRibbon(uv, time, 
                                               0.35,  // yOffset (top)
                                               4.0,   // frequency
                                               0.05,  // amplitude
                                               2.5,   // speed
                                               0.003, // thickness
                                               highE, // energy
                                               4.0);  // phase
            float3 highColor = float3(0.5, 0.8, 1.0) * (0.5 + highE * 3.0);
            
            // Add extreme electric flashes for high hits
            highIntensity += smoothstep(0.02, 0.0, abs(uv.y - (0.35 + sin(uv.x * 4.0 + time * 2.5 + 4.0) * 0.05))) * highE * 2.0;
            
            finalColor += highColor * highIntensity;
            
            // Apply a subtle vignette to darken the extreme edges so the ribbons emerge smoothly
            float vignette = smoothstep(1.0, 0.4, abs(uv.x));
            finalColor *= vignette;
            
            return float4(finalColor * u.dim, 1.0);
        }
        """
    }
}
