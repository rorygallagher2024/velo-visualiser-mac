import Foundation
import Metal

/// "Waveform 3D" — ported from Android.
///
/// The rolling waveform's three band envelopes stood up in space: three
/// translucent glowing curtains, lilac highs nearest, violet mids, indigo bass
/// at the back, running away toward a vanishing point with the newest audio
/// beside the camera. Nine seconds of history receding into haze, flowing
/// toward you.
///
/// Deliberately NOT a raymarch. With the camera beside the lanes, each curtain
/// is a single ray-plane intersection per pixel: three analytic hits,
/// front-to-back over-composited, done. Depth stays continuous with no row
/// quantisation.
///
/// It shares `WaveHistory` with the flat Waveform, so the two can never
/// disagree about what the wave IS, only about how to stage it.
///
/// Two stagings of the same corridor, because they want opposite things.
///
/// `.room` is the Android original. Distance mixes toward the colour of the air
/// between, there is a grid floor, each curtain spills light onto it, and a deep
/// violet ambience fills the vanishing region. Every one of those is a depth
/// cue, and together they read as a place.
///
/// `.void` is the same geometry with the lights off, on pure black. All of that
/// goes, which means the depth cues have to come from somewhere else: parallax
/// from the camera sway, haze falling to black rather than to fog, and the
/// floor reflection standing in for a floor of black glass. Nothing is drawn
/// that is not the wave or its own reflection.
final class Waveform3DScene: VeloScene {

    enum Style {
        /// Violet air, grid floor, contact light, ambience.
        case room
        /// Pure black. The curtains and their reflection, and nothing else.
        case void
    }

    let name: String
    private let style: Style

    private let history = WaveHistory()
    private var energy = BandEnergy()

    init(style: Style = .room) {
        self.style = style
        name = style == .room ? "Waveform 3D" : "Waveform 3D Void"
    }

    var historyBuffer: MTLBuffer? { history.gpuBuffer }

    func prepare(device: MTLDevice) { history.prepare(device: device) }

    func update(audio: AudioEngine, dt: Float) {
        history.consume(audio: audio)
        energy.update(bands: audio.currentBands(), dt: dt)
    }

    func writeData(into pointer: UnsafeMutableRawPointer) {
        // head, dynamics, envelope. Beat marks would be the fourth, but they
        // need a shared musical clock the Mac app does not have, and an etched
        // mark is a permanent record: onset detection is not good enough to
        // write guesses into a timeline.
        var packed = SIMD4<Float>(history.headFraction, history.dynamics, energy.envelope, 0)
        pointer.copyMemory(from: &packed, byteCount: MemoryLayout<SIMD4<Float>>.size)
    }


    /// The grid floor and the light each curtain spills onto it. Omitted
    /// entirely in `.void` rather than multiplied by zero, so that variant does
    /// not pay for a floor it never shows.
    private var floorSection: String {
        guard style == .room else { return "" }
        return """
            if (rd.y < -0.001) {
                float floorHaze = exp(-gz * haze0) * (1.0 - acc);

                // Screen-space line width. A fixed width in grid units makes
                // distant lines thinner and thinner in pixels until they fall
                // below the sample grid and crawl as they scroll; scaling by
                // the derivative keeps every line the same PIXEL width however
                // far away. Past Nyquist they fade rather than aliasing into a
                // bright band at the horizon.
                float zd = min(fract(zu), 1.0 - fract(zu));
                float zLine = smoothstep(zw * GRID_PX, 0.0, zd)
                            * (1.0 - smoothstep(0.18, 0.45, zw));
                float xd = min(fract(xu), 1.0 - fract(xu));
                float xLine = smoothstep(xw * GRID_PX, 0.0, xd)
                            * (1.0 - smoothstep(0.18, 0.45, xw));
                col += max(zLine, xLine) * 0.25 * floorHaze * float3(0.35, 0.15, 0.75);

                // CONTACT GLOW: each curtain spills light onto the floor around
                // its base. Without this the curtains and the grid are lit by
                // separate worlds and the wave hovers over a backdrop instead
                // of standing in a room. Contact is what puts an object IN a
                // space.
                for (int k = 0; k < 3; k++) {
                    float z0 = laneX[k] / (uvEdge + LOOK_X + sway - laneX[k] * flare);
                    float fAge = (gz - z0) * SLICES_PER_Z;
                    if (fAge < 0.0 || fAge > 3800.0) { continue; }
                    int t = wrapSlice(int(s.head - 1.0 - fAge)) * FIELDS;
                    float3 hf = float3(h[t], h[t + 1], h[t + 2]);
                    // The lane's x at THIS depth, so the pool of light tracks
                    // its sheared curtain instead of sliding out from under it.
                    float lx = laneX[k] * (1.0 + flare * gz);
                    float dx = gx - lx;
                    col += laneCol[k] * exp(-dx * dx * SPILL_TIGHT) * hf[2 - k]
                         * SPILL_AMT * floorHaze;
                }
            }
        """
    }

    /// The violet ambience filling the vanishing region.
    private var ambienceSection: String {
        guard style == .room else { return "" }
        return """
            // Deep violet ambience toward the vanishing region, so the curtains
            // dissolve into atmosphere rather than into black paper. The breath
            // is deliberately gentle: this is ATMOSPHERE, not a reading. A hard
            // flash competes with the curtains, strobes at the beat rate, and
            // swamps the slow dynamics the whole room is staged around.
            float glow = exp(-abs(uv.y + LOOK_Y) * 6.0)
                       * exp(-max(uv.x + LOOK_X, 0.0) * 1.4);
            col += float3(0.25, 0.08, 0.55) * glow * (GLOW_BASE + GLOW_BEAT * s.env);
        """
    }

    var shaderSource: String {
        """
        \(Self.shaderPreamble)

        struct Stage { float head; float dyn; float env; float showBeats; };

        \(Self.fullscreenVertexShader)

        constant int FIELDS = \(WaveHistory.fields);

        constant float3 BASS_COL = float3(0.36, 0.10, 0.92);
        constant float3 MID_COL  = float3(0.66, 0.22, 1.00);
        constant float3 HI_COL   = float3(0.80, 0.56, 1.00);

        // Stage geometry. Camera at x = 0 looking down +z with a slight
        // rightward pan and downward tilt; the three curtains are vertical
        // planes standing on the ground, their height the band envelope at the
        // depth the ray crosses them. The NEAREST lane is the SHORTEST band
        // (highs) so it never walls off the scene, and the tall indigo bass
        // ridge closes the back.
        constant float CAM_Y  = 0.55;
        constant float LOOK_X = 0.30;
        constant float LOOK_Y = -0.14;
        constant float CURTAIN_H = 0.95;
        constant float SLICES_PER_Z = 480.0;

        // The corridor breathes. All of these ride ONE dynamics value, so a
        // drop reads as a single gesture (the room opening) rather than as
        // three effects twitching independently.
        constant float HAZE_QUIET = 0.55;      // thick: about four seconds visible
        constant float HAZE_LOUD  = 0.16;      // clear: the whole corridor
        constant float CAM_DYN = 0.25;         // quiet rides high, loud sinks
        constant float FLARE = 0.18;           // lanes spread and draw in

        // Aerial perspective mixes toward the FOG's colour, not toward black.
        // Distance should read as air, not as the lights being dimmed.
        constant float3 FOG_COL = \(style == .room
            ? "float3(0.30, 0.14, 0.62)"
            : "float3(0.0, 0.0, 0.0)");
        constant float AERIAL = 0.80;
        // Depth of field, FAR SIDE ONLY. Softening the near side would read as
        // the scene being out of focus, or worse, as low resolution.
        constant float DOF = 0.35;
        constant float FOCAL_Z = 1.8;
        constant float GLOW_BASE = 0.80;
        constant float GLOW_BEAT = 0.35;

        // Margin past the right frame edge where each lane's "now" line sits.
        // Keep it SMALL: because the birth line is off-screen, audio at the
        // visible edge has already aged in proportion to this margin, worse on
        // the deeper lanes, and it BREATHES with the camera pan. At 0.05 the
        // bass ridge sat about 208 ms behind, swinging with the sway.
        constant float EDGE_MARGIN = 0.01;

        // Curtain thickness for the volumetric term. Larger is denser and more
        // fog-like, smaller is sheer.
        constant float SLAB_W = 0.75;
        constant float SPILL_TIGHT = 14.0;
        constant float SPILL_AMT = 0.35;
        constant float GRID_PX = 1.2;

        // 9-tap Gaussian, sigma about 2.5 columns.
        constant float GAUSS[5] = { 0.2235, 0.1924, 0.1211, 0.0559, 0.0189 };

        // Bitwise wrap. Column indices go negative constantly (head minus age),
        // and 4096 is a power of two, so the mask is both well defined and
        // cheaper than a modulo.
        static inline int wrapSlice(int si) { return si & 4095; }

        // Gaussian-weighted envelope with sub-column interpolation. The blur is
        // what stops the curtains stairstepping along the z axis, and sliding
        // the kernel by the fraction is what stops that blur itself popping
        // column to column.
        static inline float3 envAt(device const float *h, float s) {
            int c = int(floor(s));
            float f = fract(s);
            float3 sum = float3(0.0);
            for (int k = -4; k <= 5; k++) {
                float w0 = (abs(k) <= 4) ? GAUSS[abs(k)] : 0.0;
                float w1 = (abs(k - 1) <= 4) ? GAUSS[abs(k - 1)] : 0.0;
                float wk = w0 * (1.0 - f) + w1 * f;
                int t = wrapSlice(c + k) * FIELDS;
                sum += float3(h[t], h[t + 1], h[t + 2]) * wk;
            }
            return sum;
        }

        fragment float4 veloFragment(VSOut in [[stage_in]],
                                     constant Uniforms &u [[buffer(0)]],
                                     constant Stage &s [[buffer(1)]],
                                     device const float *h [[buffer(2)]])
        {
            float2 orbit = float2(sin(u.time * 0.31) + 0.5 * sin(u.time * 0.13 + 1.7),
                                  cos(u.time * 0.27) + 0.5 * cos(u.time * 0.19 + 0.9))
                         * 0.0015 * u.resolution.y;
            float2 frag = float2(in.position.x, u.resolution.y - in.position.y) - orbit;
            float2 uv = (frag - 0.5 * u.resolution) / u.resolution.y;

            // Camera drift. Motion parallax is the strongest depth cue there
            // is, and a static camera wastes it: with the lanes at different
            // depths a slow pan SHEARS them against each other, which reads as
            // space immediately rather than having to be inferred from
            // perspective. Two incommensurate periods so it never resolves into
            // an obvious loop.
            float sway = 0.07 * sin(u.time * 0.083) + 0.025 * sin(u.time * 0.037 + 2.1);

            // One dynamics value stages the whole room. It is loudness relative
            // to the track's own recent reference, so it says "breakdown" or
            // "drop" rather than "how far is the volume slider up".
            float dyn = clamp(s.dyn, 0.0, 1.0);
            float camY = CAM_Y + 0.06 * sin(u.time * 0.061 + 1.3) + CAM_DYN * (0.45 - dyn);
            // Modelling the flare as x = laneX * (1 + flare*z) keeps the hit
            // analytic: t = laneX / (rd.x - laneX*flare*rd.z).
            float flare = FLARE * (dyn - 0.45);
            float haze0 = mix(HAZE_QUIET, HAZE_LOUD, dyn);

            float3 rd = normalize(float3(uv.x + LOOK_X + sway, uv.y + LOOK_Y, 1.0));

            float laneX[3] = { 0.30, 0.72, 1.14 };     // highs, mids, bass
            float3 laneCol[3] = { HI_COL, MID_COL, BASS_COL };

            float3 col = float3(0.0);
            float acc = 0.0;
            float uvEdge = 0.5 * u.resolution.x / u.resolution.y + EDGE_MARGIN;

            for (int k = 0; k < 3; k++) {
                if (acc > 0.985) { break; }
                // Sheared plane, so the denominator carries the tilt. Non
                // positive means the ray never meets this lane in front of us.
                float den = rd.x - laneX[k] * flare * rd.z;
                if (den < 0.03) { continue; }
                float t = laneX[k] / den;
                float z = t * rd.z;
                float y = camY + t * rd.y;

                // Nothing can be drawn far above the tallest curtain or below
                // its reflection, so skip the Gaussian entirely.
                if (abs(y) > 1.1) { continue; }

                // Birth depth: where this lane's now-line projects just past
                // the right frame edge, so every visible pixel has age > 0 and
                // the age at the edge is about zero. The flare shifts where
                // that is, so it belongs here too, or the wave slides sideways
                // as the room breathes.
                float z0 = laneX[k] / (uvEdge + LOOK_X + sway - laneX[k] * flare);
                float age = max((z - z0) * SLICES_PER_Z, 0.0);
                if (age > 3800.0) { continue; }

                float3 bands = envAt(h, s.head - 1.0 - age);
                // Highs go in front, so the lane index runs opposite to the
                // stored band order.
                float hgt = bands[2 - k] * CURTAIN_H;

                // Pixel footprint in world units at this distance, for AA,
                // widened past the focal plane for the far-side depth of field.
                // Capped so a short curtain can still reach full opacity rather
                // than dissolving into its own blur.
                float aaW = min(t * 1.8 / u.resolution.y
                              * (1.0 + DOF * max(z - FOCAL_Z, 0.0)), 0.05);

                float haze = exp(-z * haze0);
                haze *= 1.0 - smoothstep(3300.0, 3800.0, age);

                // A zero-height curtain must draw NOTHING. The fill's smoothstep
                // at h = 0 still half covers the first pixel above the ground
                // line, which paints a glowing baseline down every empty lane.
                float hGate = smoothstep(0.006, 0.028, hgt);

                float depthT = smoothstep(0.0, 2400.0, age);
                float3 c = mix(laneCol[k], FOG_COL, depthT * AERIAL);

                // MEDIUM DENSITY, not coverage: how thick the glowing medium is
                // here. The slab integral below turns it into an alpha.
                float medium = 0.0;
                if (y >= 0.0) {
                    float fill = smoothstep(hgt + aaW, hgt - aaW, y);
                    // Dim at the ground, bright at the crest. No separate crest
                    // sample: that aliased into scattered bright dots because
                    // the height jumps between pixels.
                    medium = fill * (0.2 + 0.8 * clamp(y / max(hgt, 1e-3), 0.0, 1.0));
                } else {
                    // Polished floor reflection: the same envelope mirrored,
                    // fading fast below the ground line.
                    float ry = -y;
                    medium = smoothstep(hgt + aaW, hgt - aaW, ry) * 0.13 * exp(-ry * 2.6);
                }

                // VOLUMETRIC SLAB, not a decal. Optical depth is density times
                // the path length through it, and the path through a
                // plane-parallel slab is thickness / rd.x, so a curtain crossed
                // at a grazing angle really is denser than one met face on.
                // Infinitely thin planes are why curtains read as glowing
                // sheets; this is what makes them read as volumes.
                float pathLen = SLAB_W / max(rd.x, 0.06);
                float a = (1.0 - exp(-medium * hGate * pathLen)) * haze;
                // Born hot, like the flat Waveform's pen.
                c *= 2.5 + 2.0 * exp(-age / 240.0);

                col += (1.0 - acc) * a * c;
                acc += (1.0 - acc) * a;
            }

            // Perspective grid floor, anchoring the space. The coordinates and
            // their screen footprints are computed for EVERY pixel and only
            // used below the horizon: fwidth() in non-uniform control flow is
            // undefined, and the horizon is exactly where neighbouring pixels
            // disagree about whether they are in the branch.
            float tFloor = -camY / min(rd.y, -0.001);
            float gz = tFloor * rd.z;
            float gx = tFloor * rd.x;
            float zu = (gz * SLICES_PER_Z + s.head) / 120.0;
            float xu = gx / 0.42;
            float zw = max(fwidth(zu), 1e-5);
            float xw = max(fwidth(xu), 1e-5);

        \(floorSection)

        \(ambienceSection)

            // Ordered dither. The translucent curtains fading into haze
            // quantise into wide angled bars on an 8-bit path. Bayer reads as a
            // static texture the eye ignores; random noise twinkles.
            int bayer[16] = { 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 };
            int bx = int(in.position.x) % 4;
            int by = int(in.position.y) % 4;
            col += (float(bayer[by * 4 + bx]) / 16.0 - 0.5) * (1.5 / 255.0);

            return float4(col * u.dim, 1.0);
        }
        """
    }
}
