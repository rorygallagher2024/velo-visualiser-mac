import Foundation

/// "Tunnel" — ported from Android.
///
/// An infinite hexagonal corridor, entirely in a fragment shader. Lows pulse the
/// bore and send a ripple travelling away down the corridor rather than scaling
/// the whole thing uniformly; mids slide the wall colour; highs strobe the ribs.
///
/// The two things that make it read as depth rather than as a pattern are the
/// fog — walls fade to absolute black toward the centre, which is infinitely far
/// away — and the derivative-based line width, which keeps the wireframe one
/// pixel wide and lets it dissolve honestly as it converges on the vanishing
/// point instead of aliasing into noise.
final class TunnelScene: VeloScene {

    let name = "Tunnel"

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

        struct Audio { float low; float mid; float high; float env; };

        \(Self.fullscreenVertexShader)

        // Regular-hexagon distance field, which keeps the 6-fold symmetry exact.
        static inline float hexDist(float2 p) {
            p = abs(p);
            return max(dot(p, float2(0.866025, 0.5)), p.y);
        }

        static inline float3 palette(float t) {
            return 0.5 + 0.5 * cos(6.28318 * (t + float3(0.0, 0.33, 0.67)));
        }

        // Analytically antialiased line at every integer of c. The derivative
        // width keeps edges crisp and dissolves lines as they converge on the
        // vanishing point rather than letting them alias into speckle.
        static inline float aaLine(float c) {
            float f = fract(c);
            float d = min(f, 1.0 - f);
            float w = fwidth(c) * 1.5;
            return 1.0 - smoothstep(0.0, w, d);
        }

        fragment float4 veloFragment(VSOut in [[stage_in]],
                                     constant Uniforms &u [[buffer(0)]],
                                     constant Audio &s [[buffer(1)]])
        {
            float aspect = u.resolution.x / max(u.resolution.y, 1.0);

            // Burn-in protection: the corridor is sampled at a slowly orbiting
            // offset so fixed lines never sit on the same pixels.
            float2 orbit = float2(sin(u.time * 0.31) + 0.5 * sin(u.time * 0.13 + 1.7),
                                  cos(u.time * 0.27) + 0.5 * cos(u.time * 0.19 + 0.9)) * 1.5;

            float2 p = float2(in.position.x, u.resolution.y - in.position.y);
            float2 uv = (p + orbit) / u.resolution - 0.5;
            uv.x *= aspect;

            float hd = hexDist(uv);
            float ang = atan2(uv.y, uv.x);

            // Depth down the corridor: hd -> 0 is infinitely far (screen centre),
            // large hd is right at the viewport.
            float bore = 0.16 + s.low * 0.10;
            float z0 = u.time * 0.5 + bore / max(hd, 1e-3);

            // A bass ripple that STARTS at the viewpoint and travels into the
            // depth, rather than a uniform scale. The phase advances with z and
            // recedes with time, so crests propagate away down the corridor.
            float ripple = s.low * 0.6 * sin(z0 * 3.14159 - u.time * 4.0);
            float z = z0 + ripple;

            float rings = aaLine(z);
            float ribs = aaLine(ang / 6.28318 * 6.0);
            float wire = max(rings, ribs * 0.8);

            float3 col = palette(z * 0.06 + s.mid * 1.5) * wire;

            // Atmospheric fog to absolute darkness at the centre. Without this
            // the corridor reads as a flat pattern, because nothing says which
            // end is far away.
            float fog = 1.0 - exp(-hd * 3.5);
            col *= fog;

            // A ~60 s LFO undulates the static wireframe so fixed corridor lines
            // never burn in. The reactive strobe below is deliberately excluded.
            col *= 0.85 + 0.15 * sin(u.time * 0.10472);

            // Sharp neon accents on the rings for hats and percussion, driven
            // well past 1.0 so they read as peak-nit flashes rather than clipped
            // white on an HDR surface.
            float strobe = pow(s.high, 2.0);
            col += rings * strobe * float3(0.55, 0.85, 1.0) * fog * 5.0;

            // Ripple crests overdrive the walls as the wave travels away.
            col *= 1.0 + s.low * 2.0 * max(ripple, 0.0);

            return float4(themeGrade(col, u) * u.dim, 1.0);
        }
        """
    }
}
