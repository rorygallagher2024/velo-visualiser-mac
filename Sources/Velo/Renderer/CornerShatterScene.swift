import Foundation

/// "Corner Shatter" — beat-triggered geometric fragments that burst inward from
/// each corner and fade.
///
/// Each corner owns a pool of shards. When the envelope is hot, shards spray
/// inward from the corner across the screen, decelerate, and fade. Bass controls
/// fragment size, treble adds a bright sparkle on fresh shards. Between beats the
/// screen goes dark — this visual is event-driven, not ambient.
final class CornerShatterScene: VeloScene {

    let name = "Corner Shatter"

    private static let shards = 6000

    let draw = SceneDraw.points(CornerShatterScene.shards)

    private var energy = BandEnergy()
    private var smoothedBass: Float = 0
    private var smoothedHigh: Float = 0

    func update(audio: AudioEngine, dt: Float) {
        energy.update(bands: audio.currentBands(), dt: dt)
        smoothedBass += (energy.low - smoothedBass) * min(dt * 6, 1)
        smoothedHigh += (energy.high - smoothedHigh) * min(dt * 10, 1)
    }

    func writeData(into pointer: UnsafeMutableRawPointer) {
        let p = pointer.bindMemory(to: Float.self, capacity: 3)
        p[0] = energy.envelope
        p[1] = smoothedBass
        p[2] = smoothedHigh
    }

    var shaderSource: String {
        """
        \(Self.shaderPreamble)

        struct ShatterData {
            float envelope;
            float bass;
            float high;
        };

        constant uint SHARDS = \(Self.shards);

        struct VSOut {
            float4 position [[position]];
            float  size     [[point_size]];
            float  age;
            float  corner;
        };

        static inline float hash11(float p) {
            p = fract(p * 0.1031);
            p *= p + 33.33;
            p *= p + p;
            return fract(p);
        }

        vertex VSOut veloVertex(uint vid [[vertex_id]],
                                constant Uniforms &u [[buffer(0)]],
                                constant ShatterData &s [[buffer(1)]])
        {
            float aspect = u.resolution.x / max(u.resolution.y, 1.0);
            float dpi = max(u.resolution.y / 1080.0, 1.0);

            int corner = int(vid) % 4;
            float seed = float(int(vid) / 4);

            // Corner origins in aspect space (x spans ±aspect, y spans ±1).
            // Dividing x by aspect at the end maps to clip space.
            float2 origin;
            if (corner == 0)      origin = float2(-aspect,  1.0);
            else if (corner == 1) origin = float2( aspect,  1.0);
            else if (corner == 2) origin = float2( aspect, -1.0);
            else                  origin = float2(-aspect, -1.0);

            // Each shard cycles on its own staggered clock.
            float stagger = hash11(seed * 0.137 + float(corner) * 5.7) * 0.8;
            float life = 1.2 + hash11(seed * 0.419) * 1.0;
            float phase = fract(u.time / life - stagger);

            // Envelope gates visibility: quiet = nothing on screen.
            float trigger = s.envelope;
            float vis = trigger * smoothstep(0.0, 0.02, phase)
                      * smoothstep(1.0, 0.25, phase);

            VSOut out;
            out.age = phase;
            out.corner = float(corner);

            if (vis < 0.01) {
                out.position = float4(1e6, 1e6, 0.0, 1.0);
                out.size = 0.0;
                return out;
            }

            // Direction: INWARD from corner toward centre, with wide angular spread.
            float2 inward = -normalize(origin);
            float baseAngle = atan2(inward.y, inward.x);
            float spread = (hash11(seed * 0.731 + float(corner) * 3.3) - 0.5) * 2.4;
            float angle = baseAngle + spread;
            float2 dir = float2(cos(angle), sin(angle));

            // Distance: fast launch, decelerating. Bass pushes further.
            float speed = 0.4 + hash11(seed * 0.293) * 0.7;
            float t = phase;
            float dist = t * speed * (1.0 - t * 0.5);
            dist *= 0.5 + s.bass * 1.0;

            float2 pos = origin + dir * dist;

            // Convert from aspect space to clip space.
            pos.x /= aspect;

            out.position = float4(pos, 0.0, 1.0);

            float baseSize = 2.0 + hash11(seed * 0.557) * 5.0;
            baseSize *= 1.0 + s.bass * 2.0;
            float fade = 1.0 - smoothstep(0.15, 1.0, phase);
            out.size = max(baseSize * dpi * vis * fade, 0.0);

            return out;
        }

        fragment float4 veloFragment(VSOut in [[stage_in]],
                                     float2 pc [[point_coord]],
                                     constant Uniforms &u [[buffer(0)]],
                                     constant ShatterData &s [[buffer(1)]])
        {
            float2 c = pc * 2.0 - 1.0;
            float d = dot(c, c);
            if (d > 1.0) discard_fragment();

            // Angular shard shape — Chebyshev distance for a diamond/square feel.
            float2 ac = abs(c);
            float shape = max(ac.x, ac.y);
            float core = exp(-shape * 3.0);

            // Each corner gets a distinct hue.
            float3 col;
            if (in.corner < 0.5)      col = float3(1.0, 0.2, 0.05);
            else if (in.corner < 1.5) col = float3(0.15, 0.6, 1.0);
            else if (in.corner < 2.5) col = float3(0.1, 1.0, 0.4);
            else                      col = float3(1.0, 0.6, 0.1);

            // Fresh shards flare bright (treble sparkle).
            float freshness = 1.0 - smoothstep(0.0, 0.12, in.age);
            col *= 1.0 + freshness * s.high * 5.0;

            col *= core * (0.6 + s.envelope * 2.5);
            col = themeGrade(col, u) * u.dim;

            return float4(col, 1.0);
        }
        """
    }
}
