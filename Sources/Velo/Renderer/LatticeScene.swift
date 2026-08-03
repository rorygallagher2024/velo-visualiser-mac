import Foundation

/// "Lattice" — hex outlines built to sit *over* something else.
///
/// Tunnel is the same line-art idea aimed at the opposite job: it is a centred
/// perspective, so the eye is pulled to a vanishing point. This has no focal
/// point at all — the mesh is evenly distributed edge to edge, which is what
/// lets it decorate a video feed rather than compete with it. What makes it
/// work as an overlay is a black background and thin strokes, so the feed reads
/// through the gaps. Nothing in it strobes.
///
/// Everything here is a stroke. There are no filled shapes and no discs: each
/// cell is an outline, and the reactive element is a second outline nested
/// inside it whose radius tracks that cell's band. Energy moves a line rather
/// than lighting a fill.
///
/// Three things keep it from reading as a grid with a volume knob:
///
/// **The lattice is domain-warped, not scaled.** A slow two-octave flow field
/// bends the mesh, and bass deepens the bend rather than zooming the whole
/// thing. Scaling a grid to the beat is the tell of a primitive reactive visual
/// — it moves everything at once, which is exactly the "taking over" this is
/// meant to avoid. Bending it moves the mesh *through* itself instead.
///
/// **Every cell belongs to one band.** A hash of the cell id assigns it to low,
/// mid or high, so the three bands drive three interleaved populations
/// scattered across the frame. All three are legible at once and none of them
/// owns a region, which is what makes the response read as texture rather than
/// as three meters.
///
/// **Cells breathe out of phase, under a travelling wave.** Per-cell phase stops
/// them pulsing in lockstep, and a slow diagonal sweep means a loud passage
/// crosses the frame instead of flashing it.
final class LatticeScene: VeloScene {

    let name = "Lattice"

    /// Hex cells across the short edge. Fine enough to read as a mesh, coarse
    /// enough that the strokes stay separate at 4K.
    private static let cells: Float = 7.0

    private var energy = BandEnergy()

    init() {
        // Slower than default, and slower to let go. This decorates a set, so
        // it should swell and settle rather than snap.
        energy.smoothing = 4.0
        energy.envelopeAttack = 9.0
        energy.envelopeRelease = 1.6
    }

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

        constant float CELLS = \(Self.cells);

        // Positive modulo. Metal's fmod keeps the sign of the dividend, which
        // would fold the lattice inside out across x = 0 and y = 0 — a seam
        // straight through the middle of the frame.
        static inline float2 pmod(float2 x, float2 m) {
            return x - m * floor(x / m);
        }

        // Regular-hexagon distance: 0 at the centre, 0.5 at the edge of a
        // unit-pitch cell. Same field Tunnel uses, for exact 6-fold symmetry.
        static inline float hexDist(float2 p) {
            p = abs(p);
            return max(dot(p, float2(0.866025, 0.5)), p.y);
        }

        // Nearest hex centre on a unit-pitch lattice.
        // Returns xy = position within the cell, zw = cell id.
        static inline float4 hexCell(float2 uv) {
            float2 r = float2(1.0, 1.7320508);
            float2 h = r * 0.5;
            float2 a = pmod(uv, r) - h;
            float2 b = pmod(uv + h, r) - h;
            float2 gv = dot(a, a) < dot(b, b) ? a : b;
            return float4(gv, uv - gv);
        }

        static inline float hash21(float2 p) {
            float3 p3 = fract(float3(p.x, p.y, p.x) * 0.1031);
            p3 += dot(p3, p3.yzx + 33.33);
            return fract((p3.x + p3.y) * p3.z);
        }

        static inline float vnoise(float2 p) {
            float2 i = floor(p), f = fract(p);
            f = f * f * (3.0 - 2.0 * f);
            float a = hash21(i);
            float b = hash21(i + float2(1.0, 0.0));
            float c = hash21(i + float2(0.0, 1.0));
            float d = hash21(i + float2(1.0, 1.0));
            return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
        }

        // Two octaves is enough to bend a lattice convincingly and half the
        // cost of four. Anything finer is lost once the mesh is drawn as lines.
        static inline float fbm2(float2 p) {
            return vnoise(p) * 0.65 + vnoise(p * 2.03) * 0.35;
        }

        // A stroke ON a contour, not a fill up to it. `d` is signed distance
        // from the contour, `w` the half-width, so the result is a hairline
        // either side and nothing in the interior.
        static inline float stroke(float d, float w) {
            return 1.0 - smoothstep(0.0, w, abs(d));
        }

        fragment float4 veloFragment(VSOut in [[stage_in]],
                                     constant Uniforms &u [[buffer(0)]],
                                     constant Audio &s [[buffer(1)]])
        {
            float aspect = u.resolution.x / max(u.resolution.y, 1.0);

            // Burn-in protection, as everywhere else: sample at a slowly
            // orbiting offset so a static line never owns the same pixels.
            float2 orbit = float2(sin(u.time * 0.31) + 0.5 * sin(u.time * 0.13 + 1.7),
                                  cos(u.time * 0.27) + 0.5 * cos(u.time * 0.19 + 0.9)) * 1.5;

            float2 frag = float2(in.position.x, u.resolution.y - in.position.y);
            float2 c = (frag + orbit) / u.resolution - 0.5;
            c.x *= aspect;                       // regular hexagons at any window shape

            // Lattice space, drifting slowly so the mesh is alive when silent.
            float2 uv = c * CELLS + float2(u.time * 0.055, u.time * 0.034);

            // Organic bend. Bass deepens the warp instead of scaling the mesh,
            // so a kick travels through the lattice rather than inflating it.
            float2 flow = float2(fbm2(uv * 0.42 + float2(0.0, u.time * 0.06)),
                                 fbm2(uv * 0.42 + float2(5.2, -u.time * 0.05)));
            uv += (flow - 0.5) * (0.85 + s.low * 0.75);

            float4 cell = hexCell(uv);
            float2 gv = cell.xy;
            float2 id = cell.zw;
            float hd = hexDist(gv);

            // Stroke half-width. Anchored to an exact lattice-units-per-pixel
            // figure and only allowed to track the warped derivative within a
            // narrow band. Taking fwidth of the warped coordinate alone lets
            // the noise gradient inflate the stroke until neighbouring lines
            // merge and the cell reads as solid — which is the whole failure
            // this scene is built to avoid.
            float unit = CELLS / max(u.resolution.y, 1.0);
            float dw = (fwidth(uv.x) + fwidth(uv.y)) * 0.5;
            float w = clamp(dw, unit * 0.6, unit * 1.8);

            // The mesh itself: a stroke on the cell boundary. Neighbouring
            // cells each draw their own side, and the halves meet.
            float mesh = stroke(hd - 0.5, w);

            // Which band owns this cell. Lows are given the largest share
            // because they are the part a room actually feels.
            float sel = hash21(id * 1.37);
            float bandE;
            float3 tint;
            if (sel < 0.38) {
                bandE = s.low;
                tint = float3(1.00, 0.58, 0.26);                  // warm amber
            } else if (sel < 0.76) {
                bandE = s.mid;
                tint = float3(0.30, 0.82, 0.95);                  // teal
            } else {
                bandE = s.high;
                tint = float3(0.82, 0.88, 1.00);                  // cool white
            }

            // Out-of-phase breathing, and a slow diagonal sweep so a loud
            // passage crosses the frame instead of flashing all of it.
            float phase = hash21(id + 7.31) * 6.28318;
            float breathe = 0.55 + 0.45 * sin(u.time * 0.55 + phase);
            float sweep = 0.55 + 0.45 * sin(id.x * 0.33 + id.y * 0.21 - u.time * 0.7);
            float drive = bandE * breathe * sweep;

            // The reactive element: a second hexagon nested inside the cell,
            // its radius carrying the band. A ring that grows and shrinks stays
            // line art; a disc that brightens does not. Capped well short of
            // 0.5 so it never touches the mesh and closes the cell in.
            float ringR = 0.13 + drive * 0.62;
            ringR = min(ringR, 0.37);
            float ring = stroke(hd - ringR, w * 0.85);

            // Even coverage, edge to edge. What makes this work as an overlay is
            // that the background is black and the strokes are thin, so the
            // feed reads through the gaps — not a hole cut in the middle.
            //
            // The mesh holds a floor of light so it is always present; the ring
            // is what the audio actually moves.
            float3 col = tint * (mesh * (0.30 + drive * 1.5)
                                 + ring * (0.10 + drive * 1.9));

            // Gentle overall lift, capped low on purpose. There is no strobe
            // and no clipped white anywhere in this scene.
            col *= 1.0 + s.env * 0.55;

            // ~60 s LFO, so even the resting mesh is never a fixed pattern.
            col *= 0.88 + 0.12 * sin(u.time * 0.10472);

            return float4(themeGrade(col, u) * u.dim, 1.0);
        }
        """
    }
}
