import Foundation

/// "Flux" — a volumetric kaleidoscope corridor, unique to the Mac app.
///
/// The camera drifts through an infinite twisted tunnel whose cross-section
/// is mirrored into N-fold symmetry. Three layers of volumetric glow —
/// outer wall, inner ring, fold-edge filaments — accumulate along every ray,
/// coloured by a time-cycling psychedelic palette with phase offsets per
/// layer. The kaleidoscope twists along the tunnel axis, creating spiral
/// patterns that evolve continuously. Bass breathes the tunnel radius,
/// treble sharpens the fold edges, beats flash HDR highlights.
///
/// Pure volumetric: no surface hit is needed. The glow integral IS the
/// image. This keeps the step count low (48) and the frame time short.
final class FluxScene: VeloScene {

    let name = "Flux"

    private var energy = BandEnergy()

    func update(audio: AudioEngine, dt: Float) {
        energy.update(bands: audio.currentBands(), dt: dt)
    }

    func writeData(into pointer: UnsafeMutableRawPointer) {
        let beat = BeatBus.current.visualEnvelope
        var packed = SIMD4<Float>(energy.low, energy.mid, energy.high, beat)
        pointer.copyMemory(from: &packed, byteCount: MemoryLayout<SIMD4<Float>>.size)
    }

    var shaderSource: String {
        """
        \(Self.shaderPreamble)

        struct Flux { float low; float mid; float high; float beat; };

        \(Self.fullscreenVertexShader)
        \(Self.glslMod)
        \(Self.rotation2D)

        constant float TAU   = 6.28318530718;
        constant int   STEPS = 48;
        constant float FAR   = 25.0;

        // ---- deterministic camera path (smooth, no CPU state) ----

        static inline float3 camPath(float t) {
            return float3(
                sin(t * 0.29) * 0.32 + sin(t * 0.17 + 1.9) * 0.16,
                cos(t * 0.23) * 0.24 + cos(t * 0.31 + 0.7) * 0.10,
                t * 2.2
            );
        }

        // ---- kaleidoscopic fold ----

        static inline float2 kfold(float2 p, float n) {
            float a   = atan2(p.y, p.x);
            float sec = TAU / n;
            a = gmod(a + sec * 0.5, sec) - sec * 0.5;
            return float2(cos(a), sin(a)) * length(p);
        }

        // ---- palette with boosted saturation ----

        static inline float3 pal(float t) {
            float3 c = 0.5 + 0.5 * cos(TAU * (t + float3(0.0, 0.33, 0.67)));
            float g  = dot(c, float3(0.299, 0.587, 0.114));
            return mix(float3(g), c, 1.5);
        }

        // ---- fragment ----

        fragment float4 veloFragment(VSOut in [[stage_in]],
                                     constant Uniforms &u [[buffer(0)]],
                                     constant Flux &s [[buffer(1)]])
        {
            float aspect = u.resolution.x / max(u.resolution.y, 1.0);
            float2 px = float2(in.position.x, u.resolution.y - in.position.y);
            float2 uv = (px / u.resolution - 0.5) * float2(aspect, 1.0);

            // camera — fully deterministic from time, no jank
            float camT   = u.time * 0.7;
            float3 ro    = camPath(camT);
            float3 ahead = camPath(camT + 2.5);

            float3 fwd = normalize(ahead - ro);
            float roll  = sin(u.time * 0.059) * 0.10
                        + sin(u.time * 0.097) * 0.05;
            float3 wup  = float3(sin(roll), cos(roll), 0.0);
            float3 rt   = normalize(cross(fwd, wup));
            float3 up   = cross(rt, fwd);
            float3 rd   = normalize(fwd * 0.82 + uv.x * rt + uv.y * up);

            // fold count (slow morph, 4–10)
            float rawN = 6.5 + sin(u.time * 0.059) * 1.8
                             + sin(u.time * 0.097) * 0.7;
            float n = max(floor(rawN + 0.5), 4.0);

            // tunnel radius (bass-breathing)
            float R = 1.3 + s.low * 0.3;

            // inner ring radius for second glow layer
            float Ri = R * 0.42;

            // ---- march with three-channel volumetric glow ----
            float3 col = float3(0.0);
            float t = 0.15;

            for (int i = 0; i < STEPS; i++) {
                float3 p = ro + rd * t;

                // twisted kaleidoscope
                float twist = p.z * 0.12 + u.time * 0.08;
                float2 tp   = rot2(twist) * p.xy;
                float2 fp   = kfold(tp, n);

                // secondary fold for sub-structure
                fp = abs(fp) - float2(R * 0.35, 0.0);
                fp = fp.x < fp.y ? fp.yx : fp;

                // feature distances
                float dWall  = R - length(p.xy);
                float dInner = abs(length(p.xy) - Ri) - 0.015;
                float dEdge  = length(fp);

                // step (wall-guided, clamped)
                float step = clamp(dWall * 0.75, 0.03, 1.2);

                // hue from depth + time (continuous cycling)
                float hue = p.z * 0.035 + u.time * 0.06;

                // volumetric glow accumulation
                float wg = step / (1.0 + dWall  * dWall  * 50.0);
                float ig = step / (1.0 + dInner * dInner * 160.0);
                float eg = step / (1.0 + dEdge  * dEdge  * 120.0);

                col += pal(hue)       * wg * 0.28;
                col += pal(hue + 0.4) * ig * 0.16;
                col += pal(hue - 0.2) * eg * 0.14;

                if (dWall < 0.005 || t > FAR) break;
                t += step;
            }

            // audio reactivity
            col *= 0.65 + s.beat * 1.8 + s.low * 0.25;

            // treble lifts the edge channel
            col += col * s.high * 0.4;

            // vignette
            float2 vc = uv / float2(aspect * 0.6, 0.6);
            col *= max(1.0 - 0.25 * dot(vc, vc), 0.0);

            return float4(themeGrade(col, u) * u.dim, 1.0);
        }
        """
    }
}
