import Foundation

/// "Electric Iris" — ported from Android.
///
/// A volumetric iris: a gaseous nebula surrounding a black SDF pupil. Lows
/// dilate the pupil, mids churn the FBM clouds, and highs trigger lightning
/// arcs along the pupil edge. The nebula is a ten-step volume accumulation
/// with 2D FBM faking the third dimension through a phase offset.
///
/// The spectrum drives the pupil shape per-angle: the iris breathes
/// differently at every frequency, so a kick widens the bass side while a
/// hat tightens the treble. 128 log-spaced bins are passed through the
/// scene buffer and indexed directly in the shader.
final class ElectricIrisScene: VeloScene {

    let name = "Electric Iris"

    private var energy = BandEnergy()
    private var smoothedLow: Float = 0
    private var smoothedMid: Float = 0
    private var smoothedHigh: Float = 0
    private var bins = [Float](repeating: 0, count: AudioEngine.binCount)

    func update(audio: AudioEngine, dt: Float) {
        energy.update(bands: audio.currentBands(), dt: dt)
        bins = audio.currentBins()

        let low = max(energy.low - 0.1, 0) * 1.5
        let mid = max(energy.mid - 0.1, 0) * 1.5
        let high = max(energy.high - 0.15, 0) * 1.5
        smoothedLow += (low - smoothedLow) * 0.15
        smoothedMid += (mid - smoothedMid) * 0.15
        smoothedHigh += (high - smoothedHigh) * 0.2
    }

    func writeData(into pointer: UnsafeMutableRawPointer) {
        let p = pointer.bindMemory(to: Float.self, capacity: 4 + AudioEngine.binCount)
        p[0] = smoothedLow
        p[1] = smoothedMid
        p[2] = smoothedHigh
        p[3] = energy.envelope
        bins.withUnsafeBufferPointer { buf in
            pointer.advanced(by: 4 * MemoryLayout<Float>.stride)
                .copyMemory(from: buf.baseAddress!, byteCount: AudioEngine.binCount * MemoryLayout<Float>.stride)
        }
    }

    var shaderSource: String {
        """
        \(Self.shaderPreamble)

        struct IrisData {
            float low;
            float mid;
            float high;
            float env;
            float spectrum[128];
        };

        \(Self.fullscreenVertexShader)

        static inline float hash12(float2 p) {
            float3 p3 = fract(float3(p.xyx) * 0.1031);
            p3 += dot(p3, p3.yzx + 33.33);
            return fract((p3.x + p3.y) * p3.z);
        }

        static inline float noise2D(float2 x) {
            float2 p = floor(x);
            float2 f = fract(x);
            f = f * f * (3.0 - 2.0 * f);
            float res = mix(
                mix(hash12(p), hash12(p + float2(1, 0)), f.x),
                mix(hash12(p + float2(0, 1)), hash12(p + float2(1, 1)), f.x),
                f.y);
            return res;
        }

        static inline float fbm2D(float2 p) {
            float f = 0.0;
            float amp = 0.5;
            for (int i = 0; i < 3; i++) {
                f += amp * noise2D(p);
                p *= 2.02;
                amp *= 0.5;
            }
            return f;
        }

        static inline float3 palette(float t) {
            return 0.5 + 0.5 * cos(6.28318 * (t + float3(0.0, 0.33, 0.67)));
        }

        static inline float2x2 rot(float a) {
            float c = cos(a), s = sin(a);
            return float2x2(float2(c, -s), float2(s, c));
        }

        fragment float4 veloFragment(VSOut in [[stage_in]],
                                     constant Uniforms &u [[buffer(0)]],
                                     constant IrisData &s [[buffer(1)]])
        {
            float2 res = u.resolution;
            float2 p = float2(in.position.x, res.y - in.position.y);
            float2 uv = (p - 0.5 * res) / min(res.x, res.y);

            // Beat punch.
            uv /= (1.0 + s.env * 0.05);
            uv *= 1.8;

            // Spectrum lookup per-angle: mirror the angle so the iris is symmetric.
            float ang = atan2(uv.y, uv.x);
            float aMir = abs(fract(ang / 6.28318) * 2.0 - 1.0);
            int binIdx = clamp(int(aMir * 127.0), 0, 127);
            float spec = s.spectrum[binIdx];

            // Pupil radius: dilated by bass and by the per-angle spectrum.
            float pupilRadius = 0.35 + s.low * 0.2 + spec * 0.2;
            float audioChurn = s.mid * 2.0;

            // Volumetric accumulation.
            float3 ro = float3(0.0, 0.0, -2.5);
            float3 rd = normalize(float3(uv, 1.0));
            float4 sum = float4(0.0);

            float dither = fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);

            // March the slab the nebula actually occupies, not the empty space
            // in front of it. Starting at the eye and stepping 0.3 put three of
            // ten samples inside |z| < 0.5 for a centred pixel and none at all
            // past |uv| ~ 0.85, so most of the frame paid for ten three-octave
            // fbm lookups to accumulate nothing: 9.8 ms at 8.3 Mpx, over the
            // 8.3 ms a 120 Hz frame allows. Six samples spanning the slab are
            // both cheaper and nearly twice as finely spaced.
            constexpr int STEPS = 6;
            float tEnter = (-0.5 - ro.z) / rd.z;      // rd.z > 0 by construction
            float tExit  = ( 0.5 - ro.z) / rd.z;
            float stepSize = (tExit - tEnter) / float(STEPS);
            float t = tEnter + dither * stepSize;

            for (int i = 0; i < STEPS; i++) {
                float3 pos = ro + rd * t;
                float r = length(pos.xy);

                float pupilMask = smoothstep(pupilRadius, pupilRadius + 0.15, r);
                float irisMask = smoothstep(1.5, 1.0, r) * smoothstep(0.5, 0.0, abs(pos.z));

                // Nothing here contributes, so do not pay for the noise. The
                // masks vanish outside r = 1.5, which is most of a 16:9 frame.
                if (pupilMask * irisMask < 0.004) { t += stepSize; continue; }

                float3 warpedP = pos;
                float twistAngle = r * 1.5 - u.time * 0.3 - s.mid;
                warpedP.xy = rot(twistAngle) * warpedP.xy;

                float2 noiseDomain = warpedP.xy * 2.5
                    + float2(u.time * 0.4 + audioChurn + pos.z * 0.5);
                float dens = fbm2D(noiseDomain);
                dens = smoothstep(0.4, 0.8, dens);
                dens *= pupilMask * irisMask;

                if (dens > 0.01) {
                    float3 col = palette(r * 0.4 - u.time * 0.1);
                    float limbal = smoothstep(pupilRadius + 0.2, pupilRadius, r);
                    col = mix(col, float3(1.0, 0.6, 0.1), limbal);
                    // Halved with the step count: twice as many samples each
                    // covering half the depth is the same optical thickness.
                    float alpha = dens * 0.45;
                    float4 src = float4(col * alpha, alpha);
                    sum += src * (1.0 - sum.a);
                }

                if (sum.a > 0.99) break;
                t += stepSize;
            }

            float3 finalColor = sum.rgb;

            // SDF lightning arcs along the pupil rim.
            float rUV = length(uv);
            float distToPupil = abs(rUV - pupilRadius);
            float crackle = sin(ang * 15.0 + u.time * 10.0)
                          * cos(ang * 9.0 - u.time * 6.0) * 0.05;
            float lightningSDF = abs(distToPupil - crackle);
            float spark = 0.005 / max(lightningSDF, 0.001);
            float strikePower = s.high * 1.5 + s.env + spec * 2.0;
            float strikeMask = smoothstep(0.4, 0.0, distToPupil);
            finalColor += float3(0.6, 0.9, 1.0) * spark * strikePower * strikeMask;

            finalColor *= 1.0 - 0.4 * smoothstep(0.5, 1.5, rUV);
            finalColor = themeGrade(finalColor, u) * u.dim;

            return float4(finalColor, 1.0);
        }
        """
    }
}
