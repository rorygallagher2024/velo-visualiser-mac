import Foundation

/// "Colour Bath" — Colour Wash with the colour pushed hard.
///
/// Colour Wash grades a shot. This one gels it: the same idea driven far enough
/// that the footage takes the colour rather than being tinted by it.
///
/// The way to get there is NOT simply more light. Under a Screen or Add blend
/// the overlay can only add, so raising the level of a mixed colour raises every
/// channel and the result heads for white — brighter, and paler with it. Depth
/// comes from adding a lot in one or two channels and almost nothing in the
/// rest, so the hue is forced rather than merely present.
///
/// So the palette is normalised to full saturation before it is applied: the
/// mixed hue is pushed away from its own luminance and then scaled so its
/// strongest channel sits at one. That is the most colour obtainable per unit of
/// added light, which is exactly what a gel does.
///
/// The flat term is also much smaller than Colour Wash's. An even lift across
/// the frame is the single biggest source of washing out, because it raises all
/// three channels together — the definition of desaturation.
///
/// Worth knowing: this still cannot DARKEN, because black is transparent under
/// an additive blend. A gel that deepens shadows needs a Multiply blend in OBS
/// and a mostly-white overlay, which is a different scene from this one.
final class ColourBathScene: VeloScene {

    let name = "Colour Bath"

    /// Nearly three times Colour Wash's 0.20. Safe to push this far only
    /// because the colour is saturated first — the same figure on a mixed hue
    /// would be a bright grey haze.
    private static let strength: Float = 0.58
    /// How far past its own luminance the mixed hue is pushed before use.
    private static let saturate: Float = 2.4

    private var gate = BandGate()
    private var drift: Float = 0

    func update(audio: AudioEngine, dt: Float) {
        gate.update(bands: audio.currentBands(), dt: dt)
        drift += dt * (0.030 + gate.level[2] * 0.045)
    }

    func writeData(into pointer: UnsafeMutableRawPointer) {
        let p = pointer.bindMemory(to: Float.self, capacity: 6)
        for i in 0..<4 { p[i] = gate.level[i] }
        p[4] = gate.presence
        p[5] = drift
    }

    var shaderSource: String {
        """
        \(Self.shaderPreamble)

        struct Bath {
            float lowBass;
            float midBass;
            float mids;
            float treble;
            float presence;
            float drift;
        };

        \(Self.fullscreenVertexShader)

        constant float STRENGTH = \(Self.strength);
        constant float SATURATE = \(Self.saturate);

        // Deliberately close to the channel corners. Colour Wash's palette is
        // softer and mixes to something wearable; this one is meant to gel.
        constant float3 C_LOW   = float3(1.00, 0.05, 0.10);   // deep red
        constant float3 C_MBASS = float3(1.00, 0.34, 0.00);   // orange
        constant float3 C_MID   = float3(0.10, 1.00, 0.30);   // green
        constant float3 C_HIGH  = float3(0.10, 0.40, 1.00);   // deep blue

        fragment float4 veloFragment(VSOut in [[stage_in]],
                                     constant Uniforms &u [[buffer(0)]],
                                     constant Bath &s [[buffer(1)]])
        {
            float aspect = u.resolution.x / max(u.resolution.y, 1.0);
            float2 uv = float2(in.position.x, u.resolution.y - in.position.y)
                      / u.resolution;
            float2 p = (uv - 0.5) * float2(aspect, 1.0);

            float wLow = s.lowBass;
            float wMB  = s.midBass;
            float wMid = s.mids;
            float wHi  = s.treble;
            float total = wLow + wMB + wMid + wHi + 1e-4;

            // Hue is the spectral balance; level is handled separately, so a
            // loud passage changes the colour rather than heading for white.
            float3 hue = (C_LOW * wLow + C_MBASS * wMB
                        + C_MID * wMid + C_HIGH * wHi) / total;

            // Force it. Mixing four palette entries pulls everything toward the
            // middle, and the middle is grey — so push away from the mix's own
            // luminance, then rescale so the strongest channel is at one. The
            // result carries the most colour possible per unit of light added.
            float luma = dot(hue, float3(0.2126, 0.7152, 0.0722));
            hue = max(luma + (hue - luma) * SATURATE, 0.0);
            hue /= max(max(hue.r, max(hue.g, hue.b)), 1e-4);

            // Two drifting sources, and only a small even term. Colour Wash uses
            // 0.45 here; that flat lift is the main thing that turns a gel back
            // into a haze, because it raises all three channels together.
            float t = s.drift;
            float2 poleA = float2(cos(t * 0.9), sin(t * 0.7)) * 0.42;
            float2 poleB = float2(cos(t * -0.6 + 2.1), sin(t * 0.5 + 1.3)) * 0.48;

            float fieldA = exp(-dot(p - poleA, p - poleA) * 1.7);
            float fieldB = exp(-dot(p - poleB, p - poleB) * 2.3);
            float field = 0.18 + 0.95 * fieldA + 0.70 * fieldB;

            float3 col = hue * field * STRENGTH * s.presence;

            // Bass gets its own reinforcement, kept in the red channel so it
            // deepens rather than brightens.
            col += C_LOW * fieldA * wLow * s.presence * 0.30;

            col *= 1.0 - 0.30 * dot(p, p);

            return float4(themeGrade(col, u) * u.dim, 1.0);
        }
        """
    }
}
