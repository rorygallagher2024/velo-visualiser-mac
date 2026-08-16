import Foundation

/// "Light Leak" — anamorphic streaks that sweep the frame on transients.
///
/// Built to look like something the camera did, not something laid over it. A
/// lens flare, a light catching the front element, a leak at the edge of the
/// gate: all things a viewer already accepts as part of a shot, which is why
/// they sit on footage far more comfortably than a graphic does.
///
/// Each streak is a long horizontal bar with a hard falloff across and a soft
/// one along — the shape an anamorphic lens makes of a point light. They are
/// launched from off the left edge and travel across, so nothing appears out of
/// thin air in the middle of the frame.
///
/// The launch schedule is deterministic rather than event-driven: streak `i`
/// occupies a fixed repeating slot, and audio decides how BRIGHT it is when its
/// slot comes round. That keeps the motion smooth — a streak that spawned on a
/// beat would have to appear mid-frame or jump — while still meaning a quiet
/// passage shows nothing at all.
final class LightLeakScene: VeloScene {

    let name = "Light Leak"

    private static let streaks = 5

    private var gate = BandGate()
    private var clock: Float = 0

    func update(audio: AudioEngine, dt: Float) {
        gate.update(bands: audio.currentBands(), dt: dt)
        // Sweeps run a little faster with the mids, integrated so the speed
        // change does not teleport anything.
        clock += dt * (0.10 + gate.level[2] * 0.10)
    }

    func writeData(into pointer: UnsafeMutableRawPointer) {
        let p = pointer.bindMemory(to: Float.self, capacity: 6)
        for i in 0..<4 { p[i] = gate.level[i] }
        p[4] = gate.presence
        p[5] = clock
    }

    var shaderSource: String {
        """
        \(Self.shaderPreamble)

        struct Leak {
            float lowBass;
            float midBass;
            float mids;
            float treble;
            float presence;
            float clock;
        };

        \(Self.fullscreenVertexShader)

        constant int STREAKS = \(Self.streaks);

        static inline float hash11(float n) {
            return fract(sin(n * 127.1) * 43758.5453);
        }

        fragment float4 veloFragment(VSOut in [[stage_in]],
                                     constant Uniforms &u [[buffer(0)]],
                                     constant Leak &s [[buffer(1)]])
        {
            float aspect = u.resolution.x / max(u.resolution.y, 1.0);
            float2 uv = float2(in.position.x, u.resolution.y - in.position.y)
                      / u.resolution;
            float2 p = (uv - 0.5) * float2(aspect, 1.0);

            float3 col = float3(0.0);
            // Not `half` — that is a type in MSL, and using it as a variable
            // name fails to compile with a confusing "cannot combine with
            // previous declaration specifier".
            float halfW = aspect * 0.5;

            for (int i = 0; i < STREAKS; i++) {
                float fi = float(i);
                // Each streak owns a repeating slot, offset so they do not all
                // arrive together.
                float phase = fract(s.clock * (0.55 + hash11(fi) * 0.35) + fi * 0.37);

                // Travel from just off the left edge to just off the right, so
                // nothing is ever born or dies inside the frame.
                float x = mix(-halfW - 0.35, halfW + 0.35, phase);
                float y = (hash11(fi + 11.0) - 0.5) * 0.85;
                // A slow tilt, so they are not all perfectly level.
                float tilt = (hash11(fi + 23.0) - 0.5) * 0.30;
                float dy = p.y - (y + tilt * (p.x - x));

                // Anamorphic: tight across, long along.
                float across = exp(-dy * dy * (900.0 - hash11(fi + 5.0) * 500.0));
                float along  = exp(-(p.x - x) * (p.x - x) * 2.2);
                float core   = across * along;

                // Fade in and out at the edges of the slot so nothing pops.
                float life = sin(phase * 3.14159);

                // Which band lights this streak. Spreading them means a bassy
                // track and a bright one do not look the same.
                float band = (i % 4 == 0) ? s.lowBass
                           : (i % 4 == 1) ? s.midBass
                           : (i % 4 == 2) ? s.mids
                                          : s.treble;

                // Warm leaks low, cool leaks high — the way a real flare shifts
                // with what it is catching.
                float3 tint = mix(float3(1.00, 0.55, 0.28),
                                  float3(0.60, 0.80, 1.00),
                                  fract(hash11(fi + 31.0) * 0.6 + float(i % 4) * 0.22));

                col += tint * core * life * band * 0.55;

                // A faint bloom around the streak so it sits in the shot rather
                // than on it.
                col += tint * exp(-dy * dy * 60.0) * along * life * band * 0.08;
            }

            // Nothing at all when nothing is playing.
            col *= s.presence;

            // Falls off toward the edges, like light through a lens.
            col *= 1.0 - 0.30 * dot(p, p);

            return float4(themeGrade(col, u) * u.dim, 1.0);
        }
        """
    }
}
