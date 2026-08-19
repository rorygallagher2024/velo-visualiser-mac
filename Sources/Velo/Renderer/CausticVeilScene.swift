import Foundation
import Metal

/// "Caustic Veil" — Volumetric Liquid Light & Refraction Drift for DJ Overlays.
///
/// Simulates organic, undulating underwater light caustics and prism refraction
/// creeping softly in from the screen edges and corners. The center of the frame
/// is naturally masked to keep the DJ, hands, and decks unobstructed.
///
/// Audio reactivity:
/// - Sub-bass / Kick: Drives deep wave displacement and fluid surface tension swells.
/// - Midrange: Modulates optical focal sharpness and caustic convergence webs.
/// - Treble / Hi-hats: Causes prismatic sparkles and high-frequency glitter along caustic ridges.
/// - Silence / Breakdowns: Drops to pure black via BandGate.
final class CausticVeilScene: VeloScene {

    let name = "Caustic Veil"

    private var gate = BandGate()

    // Smoothly integrated fluid time
    private var fluidClock: Float = 0
    private var shimmerClock: Float = 0

    func update(audio: AudioEngine, dt: Float) {
        gate.update(bands: audio.currentBands(), dt: dt)

        let lowBass = gate.level[0]
        let midBass = gate.level[1]
        let mids = gate.level[2]
        let treble = gate.level[3]

        // Fluid motion accelerates smoothly with bass, mids and tempo
        fluidClock += dt * (0.25 + lowBass * 0.65 + midBass * 0.40 + mids * 0.20)
        shimmerClock += dt * (0.80 + treble * 2.50)
    }

    func writeData(into pointer: UnsafeMutableRawPointer) {
        let p = pointer.bindMemory(to: Float.self, capacity: 7)
        p[0] = gate.level[0]   // lowBass
        p[1] = gate.level[1]   // midBass
        p[2] = gate.level[2]   // mids
        p[3] = gate.level[3]   // treble
        p[4] = gate.presence   // presence
        p[5] = fluidClock
        p[6] = shimmerClock
    }

    var shaderSource: String {
        """
        \(Self.shaderPreamble)

        struct CausticData {
            float lowBass;
            float midBass;
            float mids;
            float treble;
            float presence;
            float fluidClock;
            float shimmerClock;
        };

        \(Self.fullscreenVertexShader)
        \(Self.rotation2D)

        // Multi-octave chromatic caustic sampler with spectral dispersion
        static inline float sampleCausticChannel(float2 p, float t, float dispersionOffset, float sharpness, float warp) {
            float2 uv = p * 2.8;
            float2 shift = float2(dispersionOffset * 0.04, dispersionOffset * -0.03);
            uv += shift;

            // 3-pass domain-warped sinusoidal interference
            for (int i = 1; i <= 3; i++) {
                float fi = float(i);
                float2 w = float2(
                    sin(uv.y * (1.2 * fi) + t * 0.7 + fi * 1.3),
                    cos(uv.x * (1.4 * fi) - t * 0.6 + fi * 0.9)
                );
                uv += w * (warp * (0.45 / fi));
            }

            // High-curvature focal ridges
            float c1 = sin(uv.x + uv.y);
            float c2 = cos(uv.x - uv.y);
            float intensity = pow(abs(c1 * c2), sharpness);
            return intensity;
        }

        fragment float4 veloFragment(VSOut in [[stage_in]],
                                     constant Uniforms &u [[buffer(0)]],
                                     constant CausticData &s [[buffer(1)]])
        {
            if (s.presence < 0.001) {
                return float4(0.0);
            }

            float aspect = u.resolution.x / max(u.resolution.y, 1.0);
            float2 uv = float2(in.position.x, u.resolution.y - in.position.y) / u.resolution;
            float2 p = (uv - 0.5) * float2(aspect, 1.0);

            // Perimeter weighting: calculate distance towards screen boundary
            float edgeDistX = abs(uv.x - 0.5) * 2.0; // 0 at center, 1 at left/right
            float edgeDistY = abs(uv.y - 0.5) * 2.0; // 0 at center, 1 at top/bottom
            float edgeDist = max(edgeDistX, edgeDistY);

            // Bass swells the edge invasion deeper into the frame
            float maskStart = mix(0.35, 0.15, s.lowBass * 0.6);
            float edgeMask = smoothstep(maskStart, 0.95, edgeDist);

            // Corner vignette boost (caustics pool naturally in the corners)
            float cornerFactor = length(float2(edgeDistX, edgeDistY)) * 0.707;
            edgeMask = max(edgeMask, smoothstep(0.4, 1.1, cornerFactor));

            // Dynamic fluid parameters
            float warp = 0.85 + s.lowBass * 0.55 + s.midBass * 0.30;
            float sharpness = mix(3.5, 7.5, s.mids);

            // Spectral dispersion (RGB prism separation)
            float r = sampleCausticChannel(p, s.fluidClock, -1.0, sharpness, warp);
            float g = sampleCausticChannel(p, s.fluidClock,  0.0, sharpness, warp);
            float b = sampleCausticChannel(p, s.fluidClock,  1.0, sharpness, warp);

            // High-frequency treble glitter along focal points
            float glitterPhase = sin(dot(p, float2(127.1, 311.7)) + s.shimmerClock * 5.0);
            float glitter = pow(max(glitterPhase, 0.0), 32.0) * s.treble * (r + g + b) * 2.5;

            // Palette blending: Deep cyan/aquamarine base with warm golden highlights
            float3 deepWater   = float3(0.10, 0.45, 0.85);
            float3 aquaShimmer = float3(0.20, 0.90, 0.80);
            float3 goldPrism   = float3(1.00, 0.88, 0.55);

            float3 col = float3(0.0);
            col.r = r * (deepWater.r * 0.4 + goldPrism.r * 0.6);
            col.g = g * (aquaShimmer.g * 0.7 + deepWater.g * 0.3);
            col.b = b * (aquaShimmer.b * 0.5 + deepWater.b * 0.5);

            // Add shimmering refraction focus lines and glitter
            col += aquaShimmer * pow((r + g + b) * 0.333, 2.0) * (0.8 + s.mids * 1.2);
            col += goldPrism * glitter;

            // Apply edge mask and presence envelope
            col *= edgeMask * s.presence * (0.75 + s.lowBass * 0.65) * u.dim;

            // Global color grade
            float3 finalColor = themeGrade(col, u);
            return float4(finalColor, 1.0);
        }
        """
    }
}
