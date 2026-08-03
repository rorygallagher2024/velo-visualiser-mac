import Foundation

/// "Level Meter" — ported from Android.
///
/// A peak-programme bar with a gravity-dropped hairline and an overload lamp.
/// The column snaps up and glides back down (PPM ballistics), and the hairline
/// marks the high water, holds briefly, then falls.
///
/// **Mono shows one bar, stereo shows two** — and it is the same two bars either
/// way, matching Android rather than switching modes. Both channels are always
/// drawn; what changes is how far apart they sit, eased by how much genuine L/R
/// difference the data actually carries. A mono source upmixed to two channels
/// is bit-identical, so the difference is zero, the bars coincide exactly, and
/// it reads as the single bar it should. Nothing has to know whether a file is
/// playing: the signal says so.
///
/// The pair combines with `max()`, so the coincident case is one bar rather than
/// one at double brightness, and both share a single scale so left and right
/// stay comparable to each other.
///
/// Scale and overload come from `MeterCalibration` — the same fixed -60..0 dBFS
/// scale the Mechanical Meter will use, so the two instruments always agree.
final class LevelMeterScene: VeloScene {

    let name = "Level Meter"

    private let calibration = MeterCalibration()

    /// Per-channel ballistics: 0 = left, 1 = right.
    private var level: [Float] = [0, 0]
    private var peak: [Float] = [0, 0]
    private var peakVel: [Float] = [0, 0]
    private var peakHold: [Float] = [0, 0]

    /// 0 = coincident (reads as mono), 1 = fully separated.
    private var stereoMix: Float = 0
    /// Per second, not per frame: Android eases 0.02 per frame at 60 Hz, and
    /// left as a per-frame figure this would slide four times faster on a
    /// 240 Hz display.
    private let stereoEasePerSec: Float = 1.2
    /// Half-separation, in screen heights.
    private let stereoSep: Float = 0.082
    /// Below this the two channels are the same signal, not a stereo image.
    private let stereoThreshold: Float = 1e-4

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
    private var stereo = [Float](repeating: 0, count: 2048 * 2)

    func update(audio: AudioEngine, dt: Float) {
        stereo.withUnsafeMutableBufferPointer { buf in
            audio.fillStereoWaveform(buf.baseAddress!, count: pcmCount)
        }

        // Per-channel RMS, plus the largest instantaneous L/R difference — the
        // tell for whether this is a stereo image or one signal in two channels.
        let take = min(pcmCount, MeterCalibration.recentFrames)
        var sumSq: [Float] = [0, 0]
        var chDiff: Float = 0
        for i in (pcmCount - take)..<pcmCount {
            let l = stereo[i * 2]
            let r = stereo[i * 2 + 1]
            sumSq[0] += l * l
            sumSq[1] += r * r
            chDiff = max(chDiff, abs(l - r))
        }

        let rms = (0..<2).map { sqrtf(sumSq[$0] / Float(take)) }
        let db = rms.map { 20 * log10f(max($0, 1e-5)) }

        // Separate only when there genuinely are two channels carrying two
        // different things. Both conditions are needed:
        //
        //   chDiff       — an upmixed mono source is bit-identical, so a
        //                  difference of zero means one signal in two channels.
        //   right > 0    — a MONO capture device is not upmixed at all. AUHAL
        //                  fills channel 0 and leaves channel 1 silent
        //                  (measured: peakR is exactly 0.00000 on the built-in
        //                  mic), which would otherwise read as a full left
        //                  channel against an empty right one and split the
        //                  bars apart on every laptop microphone.
        let twoChannels = rms[1] > 1e-5 && chDiff > stereoThreshold
        stereoMix += ((twoChannels ? 1 : 0) - stereoMix)
            * min(stereoEasePerSec * dt, 1)

        // One shared scale, driven by the louder channel, so the two bars stay
        // comparable to each other rather than each auto-ranging alone.
        let loudest = max(db[0], db[1])
        calibration.update(db: loudest, dt: dt)
        stereo.withUnsafeBufferPointer { buf in
            calibration.updateOverload(pcm: buf, dt: dt)
        }

        for ch in 0..<2 {
            let target = calibration.position(db[ch])
            let rate = target >= level[ch] ? attackRate : releaseRate
            level[ch] += (target - level[ch]) * min(rate * dt, 1)

            if level[ch] >= peak[ch] {
                peak[ch] = level[ch]
                peakVel[ch] = 0
                peakHold[ch] = peakHoldSec
            } else if peakHold[ch] > 0 {
                peakHold[ch] -= dt
            } else {
                peakVel[ch] += peakGravity * dt
                peak[ch] = max(level[ch], peak[ch] - peakVel[ch] * dt)
            }
        }

        let rest = calibration.atRest(loudest)
        silentSec = rest ? silentSec + dt : 0
        let glowTarget: Float = silentSec > idleAfterSec ? idleGlowMin : 1
        let glowRate = glowTarget > idleGlow ? idleWakeRate : idleFallRate
        idleGlow += (glowTarget - idleGlow) * min(glowRate * dt, 1)
    }

    func writeData(into pointer: UnsafeMutableRawPointer) {
        let p = pointer.bindMemory(to: Float.self, capacity: 7)
        p[0] = level[0]
        p[1] = level[1]
        p[2] = peak[0]
        p[3] = peak[1]
        p[4] = calibration.overLit
        p[5] = idleGlow
        p[6] = stereoSep * stereoMix
    }

    var shaderSource: String {
        """
        \(Self.shaderPreamble)

        struct MeterData {
            float levelL;
            float levelR;
            float peakL;
            float peakR;
            float clip;
            float glow;
            float sep;      // half-separation; 0 means the bars coincide
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

            // Two columns, combined with max() rather than added. When the
            // source is mono the bars sit exactly on top of each other, and
            // adding them would render that as one bar at double brightness.
            float levels[2] = { s.levelL, s.levelR };
            float peaks[2]  = { s.peakL,  s.peakR  };
            float bar = 0.0;
            float pk = 0.0;
            for (int ch = 0; ch < 2; ch++) {
                float x = (ch == 0 ? -s.sep : s.sep);
                float hh = max((levels[ch] * span) * 0.5, 0.0);
                float dBar = sdRoundBox(q - float2(x, BOT + hh),
                                        float2(BAR_W, hh), min(BAR_W * 0.55, hh));
                bar = max(bar, aaFill(0.0, dBar));

                float dPk = sdRoundBox(q - float2(x, BOT + peaks[ch] * span),
                                       float2(BAR_W, 0.0011), 0.0009);
                pk = max(pk, aaFill(0.0, dPk));
            }
            col += float3(1.0) * bar * 1.25;
            col += float3(0.34) * pk;

            // Clip lamp
            float dLamp = sdRoundBox(q - float2(0.0, TOP + 0.032),
                                     float2(0.020, 0.0055), 0.0045);
            col += RED * aaFill(0.0, dLamp) * (0.06 + 1.25 * s.clip);

            return float4(themeGrade(col, u) * u.dim * s.glow, 1.0);
        }
        """
    }
}
