import Foundation

/// "Mechanical Meter" — a single white hairline pivoted below the screen,
/// swaying with true VU ballistics (~300 ms rise, gentle mechanical overshoot,
/// faint tremble under signal). Its motion paints a phosphor wake that relaxes
/// away — the only "art" is the history of the movement. A ghost peak needle
/// is kicked to the maximum, holds, then falls back under gravity. One red
/// element exists: the overload lamp past full deflection.
///
/// The dial is absolute via `MeterCalibration`: a fixed -60…0 dBFS scale, no
/// auto-gain. A given angle always means the same signal level.
///
/// Ported from Android's `MechanicalMeterScene.kt` — same physics, same shader.
final class MechanicalMeterScene: VeloScene {

    let name = "Mechanical Meter"

    private let calibration = MeterCalibration()

    private var needleLevel: Float = 0
    private var velocity: Float = 0
    private var peakLevel: Float = 0
    private var peakVelocity: Float = 0
    private var peakHold: Float = 0
    private var wakeLo: Float = 0
    private var wakeHi: Float = 0
    private var wakeEnergy: Float = 0
    private var silentSec: Float = 0
    private var atRest = false
    private var idleGlow: Float = 1
    private var timeSec: Float = 0

    private let pcmCount = 2048
    private var pcm = [Float](repeating: 0, count: 2048)

    // VU spring
    private let stiffness: Float = 550
    private let damping: Float = 30
    private let maxStepSec: Float = 0.016

    // Phosphor wake
    private let wakeRelaxPerSec: Float = 3.2
    private let wakeEnergyDecay: Float = 1.2

    // Peak pointer
    private let peakHoldSec: Float = 0.6
    private let peakGravity: Float = 1.6

    // Idle
    private let idleAfterSec: Float = 3
    private let idleGlowMin: Float = 0.4
    private let idleFallRate: Float = 1.2
    private let idleWakeRate: Float = 9

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
        atRest = calibration.atRest(db)
        let target = calibration.position(db)

        timeSec += dt
        updateMechanics(target: target, dt: dt)
    }

    private func updateMechanics(target: Float, dt: Float) {
        // True VU ballistics: ~300 ms rise with a whisper of overshoot.
        // Sub-stepped for stability: explicit Euler at this stiffness diverges
        // above ~50 ms steps, so a dropped frame would kick the needle wild.
        var remaining = dt
        while remaining > 0 {
            let h = min(remaining, maxStepSec)
            let force = (target - needleLevel) * stiffness
            velocity += (force - velocity * damping) * h
            let unclamped = needleLevel + velocity * h
            needleLevel = min(max(unclamped, 0), 1)
            if needleLevel != unclamped { velocity = 0 }
            remaining -= h
        }

        let tremble = (sinf(timeSec * 123) + 0.6 * sinf(timeSec * 287)) * 0.002 * target
        let shown = min(max(needleLevel + tremble, 0), 1)

        // Phosphor wake: the swept band relaxes exponentially toward the needle.
        let relax = 1 - expf(-wakeRelaxPerSec * dt)
        wakeLo = min(shown, wakeLo + (shown - wakeLo) * relax)
        wakeHi = max(shown, wakeHi + (shown - wakeHi) * relax)

        // Peak pointer: kicked instantly, holds, then falls under gravity.
        if shown >= peakLevel {
            peakLevel = shown
            peakVelocity = 0
            peakHold = peakHoldSec
        } else if peakHold > 0 {
            peakHold -= dt
        } else {
            peakVelocity += peakGravity * dt
            peakLevel = max(shown, peakLevel - peakVelocity * dt)
        }

        // Wake energy: how hard the needle swept.
        wakeEnergy = max(wakeEnergy - dt * wakeEnergyDecay, min(abs(velocity) * 0.5, 1))

        // Idle glow.
        silentSec = atRest ? silentSec + dt : 0
        let glowTarget: Float = silentSec > idleAfterSec ? idleGlowMin : 1
        let glowRate = glowTarget > idleGlow ? idleWakeRate : idleFallRate
        idleGlow += (glowTarget - idleGlow) * min(glowRate * dt, 1)

        needleLevel = shown
    }

    func writeData(into pointer: UnsafeMutableRawPointer) {
        let p = pointer.bindMemory(to: Float.self, capacity: 8)
        p[0] = needleLevel
        p[1] = peakLevel
        p[2] = wakeLo
        p[3] = wakeHi
        p[4] = wakeEnergy
        p[5] = min(abs(velocity) * 0.35, 0.5)  // sheen
        p[6] = calibration.overLit
        p[7] = idleGlow
    }

    var shaderSource: String {
        """
        \(Self.shaderPreamble)

        struct MeterData {
            float needle;
            float peak;
            float wakeLo;
            float wakeHi;
            float wakeEnergy;
            float sheen;
            float over;
            float glow;
        };

        \(Self.fullscreenVertexShader)

        float aaFill(float w, float d) {
            float aa = fwidth(d) + 1e-4;
            return smoothstep(w + aa, w - aa, d);
        }

        float sdSeg(float2 p, float2 a, float2 b) {
            float2 pa = p - a, ba = b - a;
            float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
            return length(pa - ba * h);
        }

        float2 dialDir(float level, float sweep) {
            float a = (level * 2.0 - 1.0) * sweep;
            return float2(sin(a), cos(a));
        }

        fragment float4 veloFragment(VSOut in [[stage_in]],
                                     constant Uniforms &u [[buffer(0)]],
                                     constant MeterData &s [[buffer(1)]])
        {
            constexpr float PIVOT_DEPTH = 0.45;
            constexpr float TIP_Y       = 0.86;
            constexpr float LAMP_AT     = 1.04;
            constexpr float3 RED        = float3(1.0, 0.27, 0.16);

            // Units of screen height; origin at bottom-centre, y up.
            float2 p = float2(in.position.x, u.resolution.y - in.position.y);
            float2 q = float2((p.x - 0.5 * u.resolution.x) / u.resolution.y,
                              p.y / u.resolution.y);

            // OLED burn-in protection: slow orbit drift.
            q += float2(
                sin(u.time * 0.31) + 0.5 * sin(u.time * 0.13 + 1.7),
                cos(u.time * 0.27) + 0.5 * cos(u.time * 0.19 + 0.9)
            ) * 0.0015;

            float halfW = 0.5 * u.resolution.x / u.resolution.y;
            float L = PIVOT_DEPTH + TIP_Y;
            float sweep = asin(clamp(0.88 * halfW / L, 0.10, 0.66));

            float2 pc = q - float2(0.0, -PIVOT_DEPTH);
            float r = length(pc);
            float th = atan2(pc.x, pc.y);
            float lvl = (th / sweep + 1.0) * 0.5;

            float3 col = float3(0.0);

            // ----- phosphor wake: the motion paints its own fading fan ------
            float inside = step(s.wakeLo, lvl) * step(lvl, s.wakeHi)
                         * step(r, L) * step(0.0, q.y);
            if (inside > 0.5) {
                float t = lvl < s.needle
                    ? (lvl - s.wakeLo) / max(s.needle - s.wakeLo, 1e-4)
                    : (s.wakeHi - lvl) / max(s.wakeHi - s.needle, 1e-4);
                t = clamp(t, 0.0, 1.0);
                float radial = smoothstep(0.02, 0.45, r) * (1.0 - smoothstep(L * 0.97, L, r));
                col += float3(0.03 + 0.10 * s.wakeEnergy) * t * t * radial;
            }

            // ----- the one red element: the overload lamp -------------------
            float2 d0 = dialDir(LAMP_AT, sweep);
            float dTick = sdSeg(pc, d0 * (L * 0.94), d0 * L);
            col += RED * aaFill(0.0015, dTick) * (0.06 + 1.25 * s.over);

            // ----- peak pointer: ghost hairline, gravity-dropped ------------
            float dPeak = sdSeg(pc, dialDir(s.peak, sweep) * 0.02,
                                    dialDir(s.peak, sweep) * L);
            col += float3(0.30) * aaFill(0.0009, dPeak);

            // ----- the needle ------------------------------------------------
            float2 nd = dialDir(s.needle, sweep);
            float dNeedle = sdSeg(pc, nd * 0.02, nd * L);
            float wTaper = mix(0.0021, 0.0011, clamp(r / L, 0.0, 1.0));
            float blade = aaFill(wTaper, dNeedle);
            float3 bladeCol = float3(1.0);
            col += bladeCol * blade * (1.35 + s.sheen);

            // a tiny luminous tip, so the reading has a focal point
            float dTip = length(pc - nd * L);
            col += bladeCol * aaFill(0.006, dTip - 0.002) * 0.9;

            return float4(themeGrade(col, u) * u.dim * s.glow, 1.0);
        }
        """
    }
}
