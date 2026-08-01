import Foundation

/// "Fractal Cathedral" — a ray-marched Mandelbox. An infinitely recursive 3D
/// structure (box-fold + sphere-fold IFS) that reads as vast alien architecture.
/// Real directional lighting + ambient occlusion give it depth; orbit-trap
/// colouring drives a drifting palette; volumetric proximity glow blooms the
/// highlights.
///
/// Audio coupling is deliberately musical, not frantic:
///   - bass slowly breathes the fold scale (the whole structure morphs),
///   - beat envelope pulses surface emission and nudges the camera dolly,
///   - treble adds a fine sparkle to the emissive rim.
final class MandelboxScene: VeloScene {

    let name = "Fractal Cathedral"

    private var energy = BandEnergy()
    private var scale: Float = 2.0
    private var emit: Float = 0
    private var spark: Float = 0
    private var hue: Float = 0

    func update(audio: AudioEngine, dt: Float) {
        energy.update(bands: audio.currentBands(), dt: dt)

        let targetScale = 1.9 + 0.18 * energy.low
        scale += (targetScale - scale) * min(dt * 2.0, 1)

        let targetEmit = 0.15 * energy.mid + 0.6 * energy.envelope
        emit += (targetEmit - emit) * min(dt * 10.0, 1)

        spark += (energy.high - spark) * min(dt * 12.0, 1)

        hue += (0.012 + energy.high * 0.04) * dt
    }

    func writeData(into pointer: UnsafeMutableRawPointer) {
        let p = pointer.bindMemory(to: Float.self, capacity: 5)
        p[0] = energy.envelope
        p[1] = scale
        p[2] = emit
        p[3] = spark
        p[4] = hue
    }

    var shaderSource: String {
        """
        \(Self.shaderPreamble)

        struct MBoxData {
            float env;
            float scale;
            float emit;
            float spark;
            float hue;
        };

        \(Self.fullscreenVertexShader)
        \(Self.rotation2D)

        #define ITER  8
        #define MARCH 56
        #define TAU 6.2831853

        constant float MINR2   = 0.25;
        constant float FIXEDR2 = 1.0;

        static inline float3 palette(float x, float hueOff) {
            return 0.5 + 0.5 * cos(TAU * (float3(1.0) * x
                        + float3(0.00, 0.33, 0.55) + hueOff));
        }

        static inline float boxDE(float3 p, float sc, thread float &trap) {
            float3 offset = p;
            float dr = 1.0;
            trap = 1e9;
            for (int i = 0; i < ITER; i++) {
                p = clamp(p, -1.0, 1.0) * 2.0 - p;
                float r2 = max(dot(p, p), 1e-6);
                if (r2 < MINR2) {
                    float t = FIXEDR2 / MINR2; p *= t; dr *= t;
                } else if (r2 < FIXEDR2) {
                    float t = FIXEDR2 / r2;    p *= t; dr *= t;
                }
                p = p * sc + offset;
                dr = dr * abs(sc) + 1.0;
                trap = min(trap, length(p));
            }
            return length(p) / abs(dr);
        }

        static inline float mapD(float3 p, float sc) {
            float t;
            return boxDE(p, sc, t);
        }

        static inline float3 calcNormal(float3 p, float sc) {
            float2 e = float2(0.0009, 0.0);
            return normalize(float3(
                mapD(p + e.xyy, sc) - mapD(p - e.xyy, sc),
                mapD(p + e.yxy, sc) - mapD(p - e.yxy, sc),
                mapD(p + e.yyx, sc) - mapD(p - e.yyx, sc)));
        }

        static inline float calcAO(float3 p, float3 n, float sc) {
            float occ = 0.0;
            float sca = 1.0;
            for (int i = 0; i < 5; i++) {
                float h = 0.012 + 0.14 * float(i) / 4.0;
                float d = mapD(p + n * h, sc);
                occ += (h - d) * sca;
                sca *= 0.65;
            }
            return clamp(1.0 - 2.2 * occ, 0.0, 1.0);
        }

        fragment float4 veloFragment(VSOut in [[stage_in]],
                                     constant Uniforms &u [[buffer(0)]],
                                     constant MBoxData &s [[buffer(1)]])
        {
            float2 fc = float2(in.position.x, u.resolution.y - in.position.y);
            float2 uv = (fc - 0.5 * u.resolution) / u.resolution.y;

            float sc = -s.scale;

            float ct = u.time * 0.07;
            float radius = 5.6 - s.env * 0.35;
            float3 ro = float3(sin(ct) * radius,
                               1.4 * sin(u.time * 0.045),
                               cos(ct) * radius);
            float3 ta = float3(0.0, 0.15 * sin(u.time * 0.06), 0.0);

            float3 fwd = normalize(ta - ro);
            float3 rgt = normalize(cross(float3(0.0, 1.0, 0.0), fwd));
            float3 up  = cross(fwd, rgt);

            float roll = sin(u.time * 0.05) * 0.25;
            float2 ruv = rot2(roll) * uv;
            float3 rd = normalize(ruv.x * rgt + ruv.y * up + 1.5 * fwd);

            float t = 0.06;
            float trap = 1e9;
            float glow = 0.0;
            bool  hit = false;
            for (int i = 0; i < MARCH; i++) {
                float3 pos = ro + rd * t;
                float tr;
                float d = boxDE(pos, sc, tr);
                glow += exp(-tr * 2.3) / (1.0 + t * t * 0.35);
                if (d < 0.0013 * t) { hit = true; trap = tr; break; }
                t += d;
                if (t > 14.0) break;
            }
            glow *= 0.06;

            float3 col = float3(0.0);

            if (hit) {
                float3 pos = ro + rd * t;
                float3 n = calcNormal(pos, sc);
                float ao = calcAO(pos, n, sc);

                float3 key = normalize(float3(0.6, 0.75, 0.45));
                float dif = clamp(dot(n, key), 0.0, 1.0);
                float fill = clamp(0.5 + 0.5 * dot(n, float3(-0.4, 0.2, -0.5)), 0.0, 1.0);
                float fre = pow(1.0 - clamp(dot(n, -rd), 0.0, 1.0), 3.0);

                float3 base = palette(trap * 0.55 + 0.15, s.hue);
                float3 cool = palette(trap * 0.55 + 0.45, s.hue);

                col  = base * dif * 1.15;
                col += cool * fill * 0.25;
                col *= ao;

                float emitVal = s.emit + s.spark * fre * 1.5;
                col += base * fre * (0.6 + emitVal * 3.0);

                col *= 0.55 + 0.45 * smoothstep(0.0, 0.6, trap);

                float3 fog = float3(0.02, 0.02, 0.05);
                col = mix(col, fog, 1.0 - exp(-t * 0.085));
            }

            float3 glowCol = palette(0.6 + 0.2 * sin(u.time * 0.1), s.hue);
            col += glowCol * glow * (1.2 + s.env * 2.5);

            col *= 1.0 - 0.25 * dot(uv, uv);

            return float4(themeGrade(col, u) * u.dim, 1.0);
        }
        """
    }
}
