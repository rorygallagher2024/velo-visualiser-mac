import Foundation
import Metal

/// "Topographic Ridge" — a wireframe landscape with contour lines, receding to
/// a horizon.
///
/// This is a rebuild. The original had four problems worth recording, because
/// each is a trap the shape of this scene invites:
///
/// **It left the screen.** Height was `spec * (0.45 + 0.55 * terr)` and then
/// multiplied again by `1 + spec * 2` toward the frame edges, so a loud passage
/// reached about 3, and `py = -0.30 + h * 1.8 * persp` put that five screens
/// above the top. Height is now normalised and clamped to 0...1 on the CPU, and
/// the projection is arranged so the *worst case* still lands at y ≈ 0.55 — see
/// `verticalBound`. The mesh cannot leave the viewport at any volume.
///
/// **Its depth axis meant nothing.** `zt` fed only the terrain noise, so every
/// row sampled the same live spectrum: the recession was decoration and the
/// landscape never moved. Depth is now *time*. Rows are committed to a history
/// ring and scroll away from the viewer, so the ground behind is what you just
/// heard.
///
/// **It was mirrored.** `fx = abs(x)` folded frequency about the centre, which
/// looks like a designed ridge but encodes every band twice and halves the
/// lateral resolution. Frequency now runs left to right, once.
///
/// **It twitched when quiet, and clipped when loud.** A bare peak-hold over raw
/// bins fed jitter straight into geometry. Height now comes from an adaptive
/// window in decibels — see below — which both settles a quiet room and keeps a
/// full-scale file off the ceiling.
///
/// What separates it from Spectral Canyon, which also puts time on the depth
/// axis: this sits low and looks out to a real horizon across the full width,
/// and it draws iso-elevation contours over the surface. The canyon is a
/// high-angle dive into colour; this is a vista in line art.
final class TopographicRidgeScene: VeloScene {

    let name = "Topographic Ridge"

    /// Mesh columns, and columns per history row. 1:1 with mesh vertices, so no
    /// lateral interpolation is needed in the shader.
    private static let cols = 96
    /// History rows, and mesh depth.
    private static let rows = 64

    /// Rows committed per second. Slow enough that a row is legible as it
    /// travels, fast enough that the landscape is clearly moving.
    private static let scrollRate: Float = 13.0

    // Projection. Keeping `lift` below `groundDrop + 1` is what bounds the
    // scene: py = horizon + persp * (lift * h - groundDrop), with h and persp
    // both at most 1, cannot exceed horizon + (lift - groundDrop).
    private static let horizonY: Float = 0.28
    private static let groundDrop: Float = 1.05
    private static let lift: Float = 1.32

    /// The highest y any vertex can reach, as a checkable fact rather than an
    /// assumption. Must stay comfortably inside clip space.
    static var verticalBound: Float { horizonY + (lift - groundDrop) }

    // Height comes from an adaptive window on the spectrum, NOT from a gain.
    //
    // `AudioEngine.currentBins()` is dB-normalised, not linear: it maps -88 dBFS
    // to 0 and -12 dBFS to 1. A silent room's mic floor lands around 0.2-0.4,
    // measured. Two earlier attempts here treated those numbers as linear
    // magnitudes and applied a multiplicative auto-gain of up to 14x, which is
    // meaningless on a logarithmic scale — a "gain" in dB is an offset, not a
    // multiply — and which rendered a silent room at 55-83% height.
    //
    // So: learn the floor per column, track the loud end across the spectrum,
    // and map the window between them onto 0...1. Silence sits at the floor and
    // maps to zero, which flattens the landscape with no separate gate needed.

    /// Per second, not per frame, so behaviour is identical at 60 and 240 Hz.
    ///
    /// Both directions are slow, so the floor settles near the *typical* quiet
    /// level. An earlier attempt fell at 9/s, which latched it onto the lowest
    /// dip of a fluctuating noise floor — after which every ordinary
    /// fluctuation read as signal and the landscape kept moving in silence.
    private static let floorUpPerSec: Float = 0.13
    private static let floorDownPerSec: Float = 0.8

    /// While a column is clearly above its floor there is real signal in it, so
    /// the estimate is nearly frozen. Without this a long loud passage teaches
    /// the floor its own level and slowly erases itself from the landscape.
    private static let floorFreeze: Float = 0.04

    /// Where the floor starts, in bin units. A plausible mic noise floor, so the
    /// first seconds after launch are already about right instead of treating
    /// the whole noise floor as signal while the estimate climbs from zero.
    private static let floorSeed: Float = 0.30

    /// Dead band above the learned floor, in bin units — about 10 dB. A band's
    /// noise floor fluctuates by several dB and this is what keeps that
    /// fluctuation out of the geometry.
    private static let floorHeadroom: Float = 0.13

    // The loud end of the window has to adapt too. With it fixed, anything at
    // 0.60 or above pinned to full height — which is most of a mic'd track and
    // essentially all of a file, since file playback reaches 0.85-1.0 where a
    // mic'd room reaches 0.45-0.60. The window now tracks both ends, so the
    // same scene works from a quiet room to a full-scale file.

    /// Rises quickly so a drop is followed within a beat or two, falls slowly so
    /// one quiet bar does not re-range the whole landscape.
    private static let ceilUpPerSec: Float = 3.0
    private static let ceilDownPerSec: Float = 0.25
    /// In signal-above-floor units, matching what `ceiling` now tracks. The old
    /// 0.55 was a raw bin level, which in these units is roughly 0.12 — leaving
    /// it would have started the window four times too wide and flattened the
    /// first seconds after launch.
    private static let ceilSeed: Float = 0.12

    /// Narrowest usable window, about 23 dB. This is what silence collapses to,
    /// and it is deliberately set to reproduce the fixed span this replaced —
    /// quiet-room behaviour was right and should not change.
    private static let minSpan: Float = 0.30

    /// Where the loudest column lands. Below 1 on purpose: peaks need somewhere
    /// to go, or a loud passage reads as clipped rather than as tall.
    private static let peakTarget: Float = 0.80

    private var energy = BandEnergy()
    /// Normalised height per column, 0...1, already windowed and smoothed.
    private var profile = [Float](repeating: 0, count: cols)
    private var noiseFloor = [Float](repeating: floorSeed, count: cols)
    /// This frame's resolved column values, kept so the window's ends can be
    /// settled before anything is mapped through them.
    private var raw = [Float](repeating: 0, count: cols)
    /// This frame's signal above each column's own floor — the quantity both
    /// ends of the window are measured in.
    private var above = [Float](repeating: 0, count: cols)
    private var ceiling: Float = ceilSeed
    /// Resolved once. This runs on the render thread, and today's session lost
    /// two debugging rounds to a path that recorded nothing, so the hook stays —
    /// just not at the cost of an environment lookup every frame.
    private let debugEnabled =
        ProcessInfo.processInfo.environment["VELO_RIDGE_DEBUG"] != nil
    private var debugClock: Float = 0
    private var scrollAccum: Float = 0
    private var head: Int = 0
    private var writeRow: Int = 0
    private var history: MTLBuffer?

    var historyBuffer: MTLBuffer? { history }

    var draw: SceneDraw {
        let quads = (Self.cols - 1) * (Self.rows - 1)
        return SceneDraw(primitive: .triangle, vertexCount: quads * 6, additive: true)
    }

    func prepare(device: MTLDevice) {
        history = device.makeBuffer(
            length: Self.rows * Self.cols * MemoryLayout<Float>.stride,
            options: .storageModeShared)
    }

    func update(audio: AudioEngine, dt: Float) {
        energy.update(bands: audio.currentBands(), dt: dt)

        let bins = audio.currentBins()
        guard bins.count == AudioEngine.binCount, let history else { return }

        // Fold the spectrum down to the mesh's columns, then smooth each column
        // in time. The smoothing is the difference between a landscape and a
        // nervous one: raw bins at low level jitter enough to read as noise
        // once they have become geometry.
        let perCol = Float(bins.count - 1) / Float(Self.cols - 1)
        let k = min(dt * 9.0, 1)
        let floorUp = min(Self.floorUpPerSec * dt, 1)
        let floorDown = min(Self.floorDownPerSec * dt, 1)
        // Pass one: resolve each column, learn its floor, and find the loudest
        // column so the window's upper end can follow it.
        var framePeak: Float = 0
        for i in 0..<Self.cols {
            let x = Float(i) * perCol
            let i0 = min(Int(x), bins.count - 1)
            let i1 = min(i0 + 1, bins.count - 1)
            let f = x - Float(i0)
            let value = bins[i0] + (bins[i1] - bins[i0]) * f
            raw[i] = value

            // Learn what this column reads when nothing is playing. Because the
            // scale is already dB, this is a genuine noise-floor estimate and
            // subtracting it is a subtraction in decibels. Frozen while the
            // column is clearly above its floor, so signal never teaches it.
            let signalPresent = value > noiseFloor[i] + Self.floorHeadroom
            let rate = signalPresent
                ? floorUp * Self.floorFreeze
                : (value > noiseFloor[i] ? floorUp : floorDown)
            noiseFloor[i] += (value - noiseFloor[i]) * rate

            // Track the peak of what the mapping actually divides: the
            // signal ABOVE this column's own floor. Using the raw peak here
            // made the window's two ends disagree — see below.
            above[i] = max(value - noiseFloor[i] - Self.floorHeadroom, 0)
            framePeak = max(framePeak, above[i])
        }

        let ceilRate = framePeak > ceiling
            ? min(Self.ceilUpPerSec * dt, 1)
            : min(Self.ceilDownPerSec * dt, 1)
        ceiling += (framePeak - ceiling) * ceilRate

        // Width of the live window, in the SAME units as the numerator: signal
        // above each column's own floor.
        //
        // This used to subtract the MEAN floor from a ceiling that tracked the
        // raw peak, while each column's numerator subtracted its own floor. The
        // two disagreed by however far a column's floor sat from the average —
        // and the treble floor is about eight times lower than the bass floor,
        // because room rumble lives at the bottom. So the right of the frame got
        // a numerator sized against a near-zero floor over a span sized against
        // a much higher one, went past 1.0, and pinned to the ceiling on
        // material that filled the whole spectrum.
        let usable = max(ceiling, Self.minSpan)
        let span = usable / Self.peakTarget

        // Pass two: map each column through the window.
        var peak: Float = 0
        for i in 0..<Self.cols {
            let h = min(max(above[i] / span, 0), 1)
            profile[i] += (h - profile[i]) * k
            peak = max(peak, profile[i])
        }

        if debugEnabled {
            debugClock += dt
            if debugClock > 0.5 {
                debugClock = 0
                // Per-third breakdown across the frequency axis, which is what
                // makes a one-sided problem visible at all. `atCeil` counts
                // columns already clamped at 1.0 by the analyser itself, before
                // this scene sees them.
                let third = Self.cols / 3
                func mn(_ a: ArraySlice<Float>) -> Float { a.reduce(0, +) / Float(a.count) }
                let atCeil = raw.filter { $0 >= 0.999 }.count
                let rawL = mn(raw[0..<third]), rawM = mn(raw[third..<(2 * third)])
                let rawR = mn(raw[(2 * third)...])
                let flL = mn(noiseFloor[0..<third]), flM = mn(noiseFloor[third..<(2 * third)])
                let flR = mn(noiseFloor[(2 * third)...])
                let hL = mn(profile[0..<third]), hM = mn(profile[third..<(2 * third)])
                let hR = mn(profile[(2 * third)...])
                VeloLog.write("ridge", String(
                    format: "RAW %.3f/%.3f/%.3f  FLOOR %.3f/%.3f/%.3f  H %.2f/%.2f/%.2f  atCeil=%d",
                    rawL, rawM, rawR, flL, flM, flR, hL, hM, hR, atCeil))
                let rawPeak = bins.max() ?? 0
                let floorPeak = noiseFloor.max() ?? 0
                let mean = profile.reduce(0, +) / Float(Self.cols)
                VeloLog.write("ridge", String(
                    format: "rawPeak=%.3f floor=%.3f ceil=%.3f span=%.3f "
                          + "heightPeak=%.3f heightMean=%.3f",
                    rawPeak, floorPeak, ceiling, span, peak, mean))
            }
        }

        scrollAccum += dt * Self.scrollRate
        commitRows(into: history)
    }

    /// Commit whole rows into the ring. Capped per frame so a hitch cannot
    /// flush the entire landscape in one go.
    private func commitRows(into history: MTLBuffer) {
        guard scrollAccum >= 1 else { return }
        let dst = history.contents().assumingMemoryBound(to: Float.self)
        var committed = 0
        while scrollAccum >= 1 && committed < 4 {
            head = writeRow
            let base = writeRow * Self.cols
            for i in 0..<Self.cols {
                // `profile` is already 0...1 from the window mapping. Clamped
                // again here because the projection's vertical bound depends on
                // it and that guarantee should not rest on an invariant held
                // somewhere else.
                dst[base + i] = min(max(profile[i], 0), 1)
            }
            writeRow = (writeRow + 1) % Self.rows
            scrollAccum -= 1
            committed += 1
        }
    }

    func writeData(into pointer: UnsafeMutableRawPointer) {
        let p = pointer.bindMemory(to: Float.self, capacity: 6)
        p[0] = Float(head)
        p[1] = scrollAccum
        p[2] = energy.low
        p[3] = energy.mid
        p[4] = energy.high
        p[5] = energy.envelope
    }

    var shaderSource: String {
        """
        \(Self.shaderPreamble)

        struct Ridge {
            float head;      // newest committed row
            float frac;      // 0..1 smooth scroll between commits
            float low;
            float mid;
            float high;
            float env;
        };

        constant int COLS = \(Self.cols);
        constant int ROWS = \(Self.rows);
        constant float HORIZON = \(Self.horizonY);
        constant float GROUND_DROP = \(Self.groundDrop);
        constant float LIFT = \(Self.lift);

        struct VSOut {
            float4 position [[position]];
            float  hgt;
            float  fog;
            float  gridU;
            float  gridV;
        };

        vertex VSOut veloVertex(uint vid [[vertex_id]],
                                constant Uniforms &u [[buffer(0)]],
                                constant Ridge &s [[buffer(1)]],
                                device const float *hist [[buffer(2)]])
        {
            int quadId = int(vid) / 6;
            int corner = int(vid) % 6;
            int cellRow = quadId / (COLS - 1);
            int cellCol = quadId % (COLS - 1);

            int dc = 0, dr = 0;
            switch (corner) {
                case 0: dc = 0; dr = 0; break;
                case 1: dc = 1; dr = 0; break;
                case 2: dc = 0; dr = 1; break;
                case 3: dc = 1; dr = 0; break;
                case 4: dc = 1; dr = 1; break;
                case 5: dc = 0; dr = 1; break;
            }
            int col = cellCol + dc;
            int row = cellRow + dr;

            // Depth is time. Row 0 is the newest committed row, at the viewer's
            // feet; higher rows are older, and further away.
            int histRow = int(s.head) - row;
            if (histRow < 0) histRow += ROWS;
            histRow = histRow % ROWS;
            float hgt = hist[histRow * COLS + col];

            // Smooth scroll is positional only: the mesh slides back by the
            // fractional progress toward the next commit, so a row's shape
            // never changes once committed.
            float zt = (float(row) + s.frac) / float(ROWS - 1);

            float depth = 1.0 + zt * 6.4;
            float persp = 1.0 / depth;

            // Frequency left to right, once. Slightly wider than the frame at
            // the near edge so the bottom corners have no gap.
            float x = float(col) / float(COLS - 1) * 2.0 - 1.0;
            float px = x * 1.14 * persp;

            // A ground plane falling away below the camera, terrain rising from
            // it. Because hgt is clamped to 0...1 on the CPU and persp is at
            // most 1, py cannot exceed HORIZON + (LIFT - GROUND_DROP), about
            // 0.55 — which is the whole fix for the version that flew off the
            // top of the screen.
            float py = HORIZON + persp * (LIFT * hgt - GROUND_DROP);

            VSOut out;
            out.position = float4(px, py, zt * 0.99, 1.0);
            out.hgt = hgt;
            out.fog = zt;
            out.gridU = float(col);
            out.gridV = float(row) + s.frac;
            return out;
        }

        // Antialiased line at every integer of c. The derivative width keeps it
        // a pixel wide and lets it dissolve toward the horizon rather than
        // aliasing into speckle.
        static inline float aaLine(float c, float scale) {
            float f = fract(c);
            float d = min(f, 1.0 - f);
            return 1.0 - smoothstep(0.0, fwidth(c) * scale, d);
        }

        fragment float4 veloFragment(VSOut in [[stage_in]],
                                     constant Uniforms &u [[buffer(0)]],
                                     constant Ridge &s [[buffer(1)]])
        {
            float h = in.hgt;

            // The mesh, and the contours the scene is named for. Iso lines run
            // along constant elevation, so they bunch on a steep face and
            // spread on a flat one — the thing that makes a contour map read as
            // terrain rather than as stripes.
            float mesh = max(aaLine(in.gridU, 1.5), aaLine(in.gridV, 1.5));
            float iso = aaLine(h * 9.0, 1.2);

            // Haze toward the horizon. Without it the far rows pile into a
            // solid band and the vista flattens into a pattern.
            float fog = pow(1.0 - in.fog, 1.5);

            // Restrained elevation ramp: cool low ground to a warm crest, the
            // top end tinted by the treble so the ridge line answers the hats.
            float3 lowC = float3(0.12, 0.26, 0.44);
            float3 midC = float3(0.24, 0.62, 0.72);
            float3 hiC  = mix(float3(0.95, 0.72, 0.42),
                              float3(1.00, 0.88, 0.72), s.high);
            float3 col = mix(lowC, midC, smoothstep(0.05, 0.45, h));
            col = mix(col, hiC, smoothstep(0.45, 0.92, h));

            // The mesh carries most of the light; contours sit under it as a
            // second, quieter set of lines.
            float ink = mesh * (0.55 + h * 1.05) + iso * (0.22 + h * 0.5);
            col *= ink * fog;

            // Elevation gain, so crests read bright on an HDR surface without
            // the flat gain that would lift the valleys with them.
            col *= 1.15 + h * 1.9;

            // Bass swells the vista a little. No strobe — a landscape should
            // not flash.
            col *= 1.0 + s.low * 0.45;

            // ~60 s LFO so a static mesh never burns in.
            col *= 0.9 + 0.1 * sin(u.time * 0.10472);

            return float4(themeGrade(col, u) * u.dim, 1.0);
        }
        """
    }
}
