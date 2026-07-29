import Foundation
import Metal

/// "Waveform" — ported from Android.
///
/// A rolling, zoomed-out oscilloscope: nine seconds of true min/max history
/// scrolling right to left, in the ultraviolet band-layer look. The data model
/// lives in `WaveHistory`.
///
/// What makes it read like a DAW waveform rather than a blob is that the three
/// band envelopes are painted as separate layers, painter style, front
/// occluding back. Bass is the tall dark body, mids over it, highs ride in
/// front as short bright needles.
///
/// Two decisions carried over from Android that were both arrived at the hard
/// way, and are worth not relitigating:
///
/// Painter compositing, not additive. Stacking the layers additively makes the
/// centre the SUM of all three, which is permanently white on any real music
/// and blows out completely under bloom. Over-compositing can never exceed a
/// layer's own colour.
///
/// The high band must stay a saturated colour. In painter order it owns the
/// whole core of the wave, so a pale near-white high paints the entire centre
/// near-white. That was tried and reverted.
///
/// Everything is evaluated in SLICE space, never from the pixel grid.
/// Screen-space estimates change with sub-pixel scroll phase and glimmer.
final class WaveformScene: VeloScene {

    let name = "Waveform"

    private let history = WaveHistory()

    var historyBuffer: MTLBuffer? { history.gpuBuffer }

    func prepare(device: MTLDevice) { history.prepare(device: device) }

    func update(audio: AudioEngine, dt: Float) { history.consume(audio: audio) }

    func writeData(into pointer: UnsafeMutableRawPointer) {
        var head = history.headFraction
        pointer.copyMemory(from: &head, byteCount: MemoryLayout<Float>.stride)
    }

    var shaderSource: String {
        """
        \(Self.shaderPreamble)

        struct Roll { float head; };

        \(Self.fullscreenVertexShader)

        constant int   SLICES  = \(WaveHistory.slices);
        constant int   FIELDS  = \(WaveHistory.fields);
        constant float VISIBLE = \(WaveHistory.visible).0;

        // Band layer palette: ULTRAVIOLET, one hue family and three rungs.
        // Indigo bass, violet mid, lilac high. The bands are told apart by a
        // LUMINANCE ladder as much as by hue, deliberately, so they stay
        // legible even stripped to greyscale.
        constant float3 BASS_COL = float3(0.36, 0.10, 0.92);
        constant float3 MID_COL  = float3(0.66, 0.22, 1.00);
        constant float3 HI_COL   = float3(0.80, 0.56, 1.00);

        static inline int wrapSlice(int si) {
            int tx = si % SLICES;
            return tx < 0 ? tx + SLICES : tx;
        }

        // The envelopes as continuous piecewise-linear functions of slice
        // position, interpolated between adjacent committed columns.
        static inline void envAt(device const float *h, float s,
                                 thread float3 &bands, thread float &up, thread float &dn) {
            float fl = floor(s);
            float f = s - fl;
            int a = wrapSlice(int(fl)) * FIELDS;
            int b = wrapSlice(int(fl) + 1) * FIELDS;
            bands = mix(float3(h[a], h[a + 1], h[a + 2]),
                        float3(h[b], h[b + 1], h[b + 2]), f);
            up = mix(h[a + 3], h[b + 3], f);
            dn = mix(h[a + 4], h[b + 4], f);
        }

        fragment float4 veloFragment(VSOut in [[stage_in]],
                                     constant Uniforms &u [[buffer(0)]],
                                     constant Roll &r [[buffer(1)]],
                                     device const float *h [[buffer(2)]])
        {
            // Family burn-in orbit: the whole instrument drifts a few pixels.
            float2 orbit = float2(sin(u.time * 0.31) + 0.5 * sin(u.time * 0.13 + 1.7),
                                  cos(u.time * 0.27) + 0.5 * cos(u.time * 0.19 + 0.9))
                         * 0.0015 * u.resolution.y;
            float2 frag = float2(in.position.x, u.resolution.y - in.position.y) - orbit;

            float x01 = frag.x / u.resolution.x;              // 0 left, 1 right
            float slice = r.head - 1.0 - (1.0 - x01) * VISIBLE;
            float spp = max(VISIBLE / u.resolution.x, 1.0);   // slices per pixel

            // Exact rasterisation of the envelope over this pixel's span.
            // ENDPOINTS give continuity in scroll position, so a column
            // drifting out of the span hands its influence over smoothly and
            // nothing pops frame to frame. The INTERIOR uses exact committed
            // heights, so a narrow peak's apex is always reached; reading only
            // the interpolation made peaks breathe as they scrolled.
            float sL = slice - 0.5 * spp;
            float sR = min(slice + 0.5 * spp, r.head - 1.0);   // never past the pen
            float3 bandL; float upL; float dnL;
            envAt(h, sL, bandL, upL, dnL);
            float3 bandR; float upR; float dnR;
            envAt(h, sR, bandR, upR, dnR);
            float3 bandExt = max(bandL, bandR);
            float upExt = max(upL, upR);
            float dnExt = max(dnL, dnR);

            int iA = int(ceil(sL));
            for (int k = 0; k < 8; k++) {
                int si = iA + k;
                if (float(si) > sR) { break; }
                int t = wrapSlice(si) * FIELDS;
                bandExt = max(bandExt, float3(h[t], h[t + 1], h[t + 2]));
                upExt = max(upExt, h[t + 3]);
                dnExt = max(dnExt, h[t + 4]);
            }

            // The wave lives in a centred band, an instrument in a space rather
            // than wall to wall.
            float halfBand = 0.5 * u.resolution.y * 0.55;
            float yc = (frag.y - 0.5 * u.resolution.y) / halfBand;
            float ext = yc >= 0.0 ? upExt : dnExt;             // signed extents
            float d = abs(yc);
            float aaPx = 1.25 / halfBand;

            float bSum = bandExt.x + bandExt.y + bandExt.z;
            float3 waveCol = (BASS_COL * bandExt.x + MID_COL * bandExt.y
                            + HI_COL * bandExt.z) / max(bSum, 1e-4);

            // The true outline as a faint shell.
            float shell = smoothstep(ext + aaPx * 2.0, ext - aaPx, d);
            float3 col = waveCol * shell * 0.16;

            // Three band envelopes, painter composited. Clamped inside the
            // side's own envelope so any asymmetry holds.
            float3 be = min(bandExt, float3(ext));
            float fillLo = smoothstep(be.x + aaPx * 2.0, be.x - aaPx, d);
            float fillMid = smoothstep(be.y + aaPx * 2.0, be.y - aaPx, d);
            float fillHi = smoothstep(be.z + aaPx * 2.0, be.z - aaPx, d);
            float3 body = float3(0.0);
            body = mix(body, BASS_COL, fillLo * 0.95);
            body = mix(body, MID_COL, fillMid * 0.85);
            body = mix(body, HI_COL, fillHi * 0.85);
            col += body * 1.05;

            // A faint halo past the peak edge keeps tips soft.
            float halo = smoothstep(ext + 14.0 * aaPx, ext, d) * (1.0 - shell);
            col += waveCol * halo * 0.10;

            // Loud columns carry a little headroom so transients read as
            // transients. Kept modest: this stacks with the live-edge boost
            // below, and the pair at 0.4 washed the right third of the wave out.
            col *= 1.0 + 0.18 * upExt * upExt;

            // The live edge: columns are born hot and cool to archival
            // brightness, so the right edge writes like a chart recorder's pen.
            // Lighting only, since the stored waveform stays an honest record.
            float age = max(r.head - 1.0 - slice, 0.0);
            col *= 1.0 + 0.28 * exp(-age / 256.0);

            // Zero axis: a dim whisper, feathered to nothing at the ends.
            float axisPx = d * halfBand;
            float ends = smoothstep(0.0, 0.12, x01) * smoothstep(1.0, 0.88, x01);
            col += float3(0.10) * smoothstep(1.6, 0.4, axisPx) * ends;

            // One LSB of dither: the dim halo and axis gradients band visibly
            // on the 8-bit path, which reads as compression.
            float dith = fract(sin(dot(frag, float2(12.9898, 78.233))) * 43758.5453);
            col += (dith - 0.5) * (1.5 / 255.0);

            return float4(col * u.dim, 1.0);
        }
        """
    }
}
