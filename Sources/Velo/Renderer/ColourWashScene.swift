import Foundation

/// "Colour Wash" — tints the footage underneath instead of drawing on it.
///
/// Built for a Screen or Add blend in OBS, where black is transparent and the
/// overlay can only ever ADD light. That rules out darkening or desaturating,
/// but it does mean a dim, broad field of colour reads as a tint on whatever is
/// behind it: lay a little red over a face and the shot warms.
///
/// So this draws almost nothing — no shapes, no edges, no stars. It is a soft
/// gradient of colour whose hue follows the spectral balance and whose strength
/// follows how much is playing. Bass warms the frame, the midrange pushes it
/// green-gold, the top end cools it. Kept deliberately dim: the brief is to
/// grade a shot, and a grade you notice as a layer has failed.
///
/// The tint is spatial, not flat. A single colour over the whole frame reads as
/// a filter slapped on top; two soft poles drifting slowly against each other
/// read as light in a room, and give the eye somewhere for the colour to come
/// from.
final class ColourWashScene: VeloScene {

    let name = "Colour Wash"

    /// Peak added brightness. Low on purpose — above roughly 0.25 this stops
    /// grading the shot and starts covering it.
    private static let strength: Float = 0.20

    private var gate = BandGate()
    private var drift: Float = 0

    func update(audio: AudioEngine, dt: Float) {
        gate.update(bands: audio.currentBands(), dt: dt)
        // Integrated, so a change of speed is a change of speed rather than a
        // jump in position.
        drift += dt * (0.035 + gate.level[2] * 0.05)
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

        struct Wash {
            float lowBass;
            float midBass;
            float mids;
            float treble;
            float presence;
            float drift;
        };

        \(Self.fullscreenVertexShader)

        constant float STRENGTH = \(Self.strength);

        // Warm through to cool, low through to high.
        constant float3 C_LOW   = float3(1.00, 0.22, 0.16);
        constant float3 C_MBASS = float3(1.00, 0.55, 0.14);
        constant float3 C_MID   = float3(0.55, 0.95, 0.45);
        constant float3 C_HIGH  = float3(0.40, 0.70, 1.00);

        fragment float4 veloFragment(VSOut in [[stage_in]],
                                     constant Uniforms &u [[buffer(0)]],
                                     constant Wash &s [[buffer(1)]])
        {
            float aspect = u.resolution.x / max(u.resolution.y, 1.0);
            float2 uv = float2(in.position.x, u.resolution.y - in.position.y)
                      / u.resolution;
            float2 p = (uv - 0.5) * float2(aspect, 1.0);

            // Mix the palette by what is actually playing. Normalised by the
            // total so the HUE is the spectral balance and the STRENGTH is
            // handled separately — otherwise a loud track would just go white.
            float wLow = s.lowBass;
            float wMB  = s.midBass;
            float wMid = s.mids;
            float wHi  = s.treble;
            float total = wLow + wMB + wMid + wHi + 1e-4;

            float3 hue = (C_LOW * wLow + C_MBASS * wMB
                        + C_MID * wMid + C_HIGH * wHi) / total;

            // Two soft poles drifting against each other. Light in a room comes
            // from somewhere; a flat field reads as a filter laid on top.
            float t = s.drift;
            float2 poleA = float2(cos(t * 0.9), sin(t * 0.7)) * 0.45;
            float2 poleB = float2(cos(t * -0.6 + 2.1), sin(t * 0.5 + 1.3)) * 0.5;

            float fieldA = exp(-dot(p - poleA, p - poleA) * 2.2);
            float fieldB = exp(-dot(p - poleB, p - poleB) * 3.0);

            // A floor of even light under the poles, so the tint reaches the
            // corners instead of stopping as two visible blobs.
            float field = 0.45 + 0.75 * fieldA + 0.55 * fieldB;

            // Bass leans the warm pole brighter, treble the cool one, so the
            // colour moves across the frame as the track does.
            float3 col = hue * field;
            col += C_LOW  * fieldA * wLow * 0.35;
            col += C_HIGH * fieldB * wHi  * 0.30;

            col *= STRENGTH * s.presence;

            // Very slight edge falloff. Real light falls off; a tint that stops
            // dead at the frame edge reads as a rectangle.
            col *= 1.0 - 0.25 * dot(p, p);

            return float4(themeGrade(col, u) * u.dim, 1.0);
        }
        """
    }
}
