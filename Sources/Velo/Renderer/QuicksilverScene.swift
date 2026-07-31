import Foundation

/// "Quicksilver" — ported from Android.
///
/// A mass of liquid metal, raymarched. A sphere whose radius is displaced by a
/// stack of spherical lobes, each owned by a band: bass moves the low orders so
/// the whole body stretches and rolls, mids raise broad swells, highs skitter
/// fine ripples across the skin. The envelope launches a real travelling wave,
/// so a hit deforms the silhouette rather than flashing a colour at it.
///
/// The thing that makes it read as metal is that there is no diffuse term
/// anywhere and no faked specular. `room()` is both the background and what the
/// surface reflects, sampled along different rays, so every highlight on the
/// metal is the actual light behind you.
///
/// Much heavier than the other scenes: 72 march steps, with a second reflection
/// tap and a four-tap gradient on every hit. The bounding-sphere rejection is
/// what makes that affordable, because most of the frame never marches at all.
final class QuicksilverScene: VeloScene {

    let name = "Quicksilver"

    private var low: Float = 0
    private var mid: Float = 0
    private var high: Float = 0
    private var loud: Float = 0
    private var energy = BandEnergy()

    func update(audio: AudioEngine, dt: Float) {
        energy.update(bands: audio.currentBands(), dt: dt)
        // Metal has mass: the form should follow the music's shape, not its
        // grain. These are slower than any other scene's on purpose.
        low += (energy.low - low) * min(dt * 3.0, 1)
        mid += (energy.mid - mid) * min(dt * 4.0, 1)
        high += (energy.high - high) * min(dt * 6.0, 1)
        loud += (energy.envelope - loud) * min(dt * 4.0, 1)
    }

    func writeData(into pointer: UnsafeMutableRawPointer) {
        var packed = (SIMD4<Float>(low, mid, high, energy.envelope), loud)
        withUnsafeBytes(of: &packed) {
            pointer.copyMemory(from: $0.baseAddress!, byteCount: 20)
        }
    }

    var shaderSource: String {
        """
        \(Self.shaderPreamble)

        struct Audio { float low; float mid; float high; float env; float loud; };

        \(Self.fullscreenVertexShader)
        \(Self.rotation2D)

        constant float R = 1.0;         // base radius of the mass
        // Must EXCEED the sum of every amplitude in surface(), or the bounding
        // sphere clips the form on a loud passage, which is the one moment it is
        // at full stretch. The sum below is about 0.59; this leaves headroom.
        constant float DISP = 0.66;
        constant int   STEPS = 72;
        constant float CAM_Z = 3.5;
        // Step scale. Displacing a sphere breaks the exact-distance property, so
        // the field is only a bound: the high-order ripple terms push the true
        // Lipschitz constant to about 1.45, and marching the full distance would
        // overshoot the skin and punch holes through it.
        constant float STEP = 0.60;

        // THE ROOM. Both the background and the thing the metal reflects, one
        // function sampled along different rays, so a highlight on the surface
        // is always the actual light behind you. Nothing here is a faked
        // specular term.
        static inline float3 room(float3 d) {
            // Deep indigo void, lifting toward the ceiling.
            float3 c = mix(float3(0.014, 0.010, 0.038),
                           float3(0.085, 0.055, 0.190),
                           smoothstep(-0.55, 0.95, d.y));
            // A large soft key light high and to the left. The exponent is what
            // gives the metal its long, drawn-out highlight.
            float key = pow(max(dot(d, normalize(float3(-0.42, 0.78, -0.46))), 0.0), 16.0);
            c += float3(0.92, 0.70, 1.00) * key * 2.30;
            // A broad violet fill from the right, so the shadow side stays
            // readable and the form never goes to a flat black lump.
            float fill = pow(max(dot(d, normalize(float3(0.72, 0.16, 0.55))), 0.0), 4.0);
            c += float3(0.26, 0.11, 0.48) * fill * 0.55;
            // A tight cool rim from below-right: the edge that sells metal.
            float rim = pow(max(dot(d, normalize(float3(0.62, -0.46, 0.38))), 0.0), 46.0);
            c += float3(0.42, 0.66, 1.00) * rim * 1.85;
            // Faint horizon band, so there is a floor to be standing over.
            c += float3(0.10, 0.05, 0.22) * exp(-abs(d.y + 0.16) * 9.0) * 0.55;
            return c;
        }

        static inline float surface(float3 d, float t, constant Audio &s) {
            float phi = atan2(d.z, d.x);
            float v = 0.0;
            // Order 2: the mass elongates and leans with the bass.
            v += s.low * 0.20 * (d.y * d.y - 0.34);
            v += s.low * 0.13 * cos(2.0 * phi + t * 0.35);
            // Orders 4-5: broad swells rolling around the body.
            v += s.mid * 0.10 * cos(4.0 * phi - t * 0.55) * (1.0 - d.y * d.y);
            v += s.mid * 0.07 * sin(5.0 * d.y * 3.14159 + t * 0.8);
            // High orders: fine chatter over the skin. Kept small on purpose,
            // because amplitude times order is what steepens the field, and a
            // spiky mass reads as noise where a weighty one reads as liquid.
            v += s.high * 0.035 * sin(9.0 * d.x + t * 1.7) * sin(8.0 * d.z - t * 1.3);
            v += s.high * 0.022 * cos(13.0 * d.y + t * 2.1);
            // A wave leaving the north pole and running down the body.
            float wave = fract(-t * 0.55) * 2.2 - 0.6;
            v += s.env * 0.10 * exp(-pow((d.y - (1.0 - wave)) * 3.4, 2.0));
            return v;
        }

        static inline float mapScene(float3 p, float t, constant Audio &s) {
            float r = length(p);
            float3 d = p / max(r, 1e-4);
            // Lipschitz-safe: displacement is scaled well under 1 so the
            // distance stays a valid, if conservative, bound for marching.
            return r - (R + surface(d, t, s));
        }

        static inline float3 normalAt(float3 p, float t, constant Audio &s) {
            // Tetrahedral 4-tap gradient: half the taps of a central difference
            // and no axis bias in the result.
            float2 e = float2(1.0, -1.0) * 0.0016;
            return normalize(
                e.xyy * mapScene(p + e.xyy, t, s) + e.yyx * mapScene(p + e.yyx, t, s) +
                e.yxy * mapScene(p + e.yxy, t, s) + e.xxx * mapScene(p + e.xxx, t, s));
        }

        fragment float4 veloFragment(VSOut in [[stage_in]],
                                     constant Uniforms &u [[buffer(0)]],
                                     constant Audio &s [[buffer(1)]])
        {
            float2 fc = float2(in.position.x, u.resolution.y - in.position.y);
            float2 uv = (fc - 0.5 * u.resolution) / u.resolution.y;
            float t = u.time;

            // Camera: a slow orbit with a gentle rise, so the highlights travel
            // across the metal and the form is read from every side.
            float3 ro = float3(0.0, 0.0, -CAM_Z);
            float3 rd = normalize(float3(uv, 1.55));
            float yaw = t * 0.13;
            float pitch = 0.16 * sin(t * 0.09);
            ro.yz = rot2(pitch) * ro.yz;  rd.yz = rot2(pitch) * rd.yz;
            ro.xz = rot2(yaw) * ro.xz;    rd.xz = rot2(yaw) * rd.xz;

            float3 col = room(rd);        // the void IS the room
            float alpha = 0.0;
            float3 surf = float3(0.0);

            // Bounding sphere: reject every ray that cannot reach the form
            // before marching a single step. Most of the frame ends here, which
            // is what makes 72 steps affordable on the rest.
            float bound = R + DISP;
            float b = dot(ro, rd);
            float c2 = dot(ro, ro) - bound * bound;
            float disc = b * b - c2;
            if (disc > 0.0) {
                float sq = sqrt(disc);
                float tIn = max(-b - sq, 0.0);
                float tOut = -b + sq;
                float td = tIn;
                float closest = 1e9;
                // Where the ray came CLOSEST, not where it stopped. A ray that
                // grazes the form runs on to the far side of the bounding sphere
                // before the loop ends, so shading at the final position would
                // paint the silhouette's soft edge with the surface from
                // somewhere behind the object.
                float tBest = tIn;
                bool hit = false;
                for (int i = 0; i < STEPS; i++) {
                    float3 p = ro + rd * td;
                    float dist = mapScene(p, t, s);
                    // Screen-relative closest approach, for a soft silhouette:
                    // a raw SDF hit gives a hard, jagged edge.
                    float rel = dist / max(td, 0.1);
                    if (rel < closest) { closest = rel; tBest = td; }
                    if (dist < 0.0009) { hit = true; break; }
                    td += dist * STEP;
                    if (td > tOut) { break; }
                }
                float px = 1.6 / u.resolution.y;
                alpha = 1.0 - smoothstep(0.0, px, closest);
                if (hit) { alpha = 1.0; }

                if (alpha > 0.001) {
                    float3 p = ro + rd * tBest;
                    float3 n = normalAt(p, t, s);
                    float3 refl = reflect(rd, n);
                    float fres = pow(1.0 - clamp(dot(-rd, n), 0.0, 1.0), 5.0);

                    // METAL: no diffuse term at all. What you see is the room,
                    // tinted by the metal's own colour, brightening toward a
                    // pure mirror at grazing angles.
                    float3 tint = mix(float3(0.62, 0.55, 0.86), float3(1.0), fres);
                    surf = room(refl) * tint;
                    // A second, blurrier reflection fills the broad shading. A
                    // single mirror tap alone reads as chrome foil rather than
                    // as a liquid with body.
                    surf += room(normalize(refl + n * 0.55)) * 0.30 * (1.0 - fres);
                    // Thin-film cast: the shading side keeps a violet sheen so
                    // the metal is never a flat grey lump.
                    surf += float3(0.16, 0.06, 0.34) * (1.0 - fres) * (0.35 + s.loud);
                    // Loud passages heat the rim. Saturated, so it picks out an
                    // edge rather than washing the body to white.
                    surf += float3(0.55, 0.30, 0.95) * pow(fres, 1.6) * s.loud * 1.1;
                }
            }

            col = mix(col, surf, alpha);

            // Ordered dither: the room is a wide, dim gradient and would
            // otherwise band into visible steps on the 8-bit path. Bayer reads
            // as texture where random noise twinkles.
            int bayer[16] = { 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 };
            int bx = int(in.position.x) % 4;
            int by = int(in.position.y) % 4;
            col += (float(bayer[by * 4 + bx]) / 16.0 - 0.5) * (1.5 / 255.0);

            return float4(themeGrade(col, u) * u.dim, 1.0);
        }
        """
    }
}
