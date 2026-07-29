import Foundation

/// "Level Meter" — ported from Android.
///
/// A peak-programme bar with a gravity-dropped hairline and an overload lamp.
/// The column snaps up and glides back down (PPM ballistics), and the hairline
/// marks the high water, holds briefly, then falls.
///
/// The Mac audio ring is mono, so this draws a single centred bar. On Android
/// a stereo variant slides two bars apart when genuine L/R difference is
/// detected; that path can be added when the Mac gains a stereo ring.
///
/// Scale and overload come from `MeterCalibration` — the same fixed -60..0 dBFS
/// scale the Mechanical Meter will use, so the two instruments always agree.
final class LevelMeterScene: VeloScene {

    let name = "Level Meter"

    private let calibration = MeterCalibration()

    private var level: Float = 0
    private var peak: Float = 0
    private var peakVel: Float = 0
    private var peakHold: Float = 0

    private var idleGlow: Float = 1
    private var silentSec: Float = 0

    private let attackRate: Float = 60
    private let releaseRate: Float = 4
    private let peakHoldSec: Float = 0.6
    private let peakGravity: Float = 1.6

    private let idleAfterSec: Float = 3
    private let idleGlowMin: Float = 0.4
    private let idleFallRate: Float = 1.2
    private let idleWakeRate: Float = 9

    private let pcmCount = 2048
    private var pcm = [Float](repeating: 0, count: 2048)

    func update(audio: AudioEngine, dt: Float) {
        pcm.withUnsafeMutableBufferPointer { buf in
            audio.fillWaveform(buf.baseAddress!, count: pcmCount)
        }

        let take = min(pcmCount, MeterCalibration.recentFrames)
        var sumSq: Float = 0
        for i in (pcmCount - take)..<pcmCount {
            sumSq += pcm[i] * pcm[i]
        }
        let rms = sqrtf(sumSq / Float(take))
        let db = 20 * log10f(max(rms, 1e-5))

        calibration.update(db: db, dt: dt)

        pcm.withUnsafeBufferPointer { buf in
            calibration.updateOverload(pcm: buf, dt: dt)
        }

        let target = calibration.position(db)

        let rate = target >= level ? attackRate : releaseRate
        level += (target - level) * min(rate * dt, 1)

        if level >= peak {
            peak = level
            peakVel = 0
            peakHold = peakHoldSec
        } else if peakHold > 0 {
            peakHold -= dt
        } else {
            peakVel += peakGravity * dt
            peak = max(level, peak - peakVel * dt)
        }

        let rest = calibration.atRest(db)
        silentSec = rest ? silentSec + dt : 0
        let glowTarget: Float = silentSec > idleAfterSec ? idleGlowMin : 1
        let glowRate = glowTarget > idleGlow ? idleWakeRate : idleFallRate
        idleGlow += (glowTarget - idleGlow) * min(glowRate * dt, 1)
    }

    func writeData(into pointer: UnsafeMutableRawPointer) {
        let p = pointer.bindMemory(to: Float.self, capacity: 4)
        p[0] = level
        p[1] = peak
        p[2] = calibration.overLit
        p[3] = idleGlow
    }

    var shaderSource: String {
        """
        \(Self.shaderPreamble)

        struct MeterData {
            float level;
            float peak;
            float clip;
            float glow;
        };

        \(Self.fullscreenVertexShader)

        float aaFill(float w, float d) {
            float aa = fwidth(d) + 1e-4;
            return smoothstep(w + aa, w - aa, d);
        }

        float sdRoundBox(float2 p, float2 b, float r) {
            float2 d = abs(p) - b + r;
            return min(max(d.x, d.y), 0.0) + length(max(d, 0.0)) - r;
        }

        fragment float4 veloFragment(VSOut in [[stage_in]],
                                     constant Uniforms &u [[buffer(0)]],
                                     constant MeterData &s [[buffer(1)]])
        {
            constexpr float BOT   = 0.12;
            constexpr float TOP   = 0.88;
            constexpr float BAR_W = 0.055;
            constexpr float3 RED  = float3(1.0, 0.27, 0.16);

            float2 p = float2(in.position.x, u.resolution.y - in.position.y);
            float2 q = float2((p.x - 0.5 * u.resolution.x) / u.resolution.y,
                              p.y / u.resolution.y);

            q += float2(
                sin(u.time * 0.31) + 0.5 * sin(u.time * 0.13 + 1.7),
                cos(u.time * 0.27) + 0.5 * cos(u.time * 0.19 + 0.9)
            ) * 0.0015;

            float span = TOP - BOT;
            float3 col = float3(0.0);

            // Whisper track
            float dT = sdRoundBox(q - float2(0.0, (BOT + TOP) * 0.5),
                                  float2(0.0011, span * 0.5), 0.0009);
            float feather = smoothstep(BOT - 0.01, BOT + 0.07, q.y) *
                            (1.0 - smoothstep(TOP - 0.07, TOP + 0.01, q.y));
            col += float3(0.05) * aaFill(0.0, dT) * feather;

            // Column
            float hh = max((s.level * span) * 0.5, 0.0);
            float dBar = sdRoundBox(q - float2(0.0, BOT + hh),
                                    float2(BAR_W, hh), min(BAR_W * 0.55, hh));
            col += float3(1.0) * aaFill(0.0, dBar) * 1.25;

            // Peak hairline
            float dPk = sdRoundBox(q - float2(0.0, BOT + s.peak * span),
                                   float2(BAR_W, 0.0011), 0.0009);
            col += float3(0.34) * aaFill(0.0, dPk);

            // Clip lamp
            float dLamp = sdRoundBox(q - float2(0.0, TOP + 0.032),
                                     float2(0.020, 0.0055), 0.0045);
            col += RED * aaFill(0.0, dLamp) * (0.06 + 1.25 * s.clip);

            return float4(col * u.dim * s.glow, 1.0);
        }
        """
    }
}
