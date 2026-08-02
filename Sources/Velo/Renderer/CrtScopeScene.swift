import Foundation
import Metal

/// "CRT Scope" — ported from Android.
///
/// A Lissajous XY oscilloscope rendered like a real analog cathode-ray tube.
/// Left audio drives X, Right drives Y, traced as one continuous beam with
/// velocity-modulated brightness: where the trace moves slowly it glows hot,
/// where it whips across it barely registers. P1 phosphor green with a
/// white-hot core at the brightest nodes, barrel curvature and a glass-tube
/// vignette.
///
/// When no stereo source is active (mic capture), falls back to a mono
/// time-base display — the horizontal axis is time, vertical is amplitude —
/// like a real scope with one probe.
final class CrtScopeScene: VeloScene {

    let name = "CRT Scope"

    private static let maxPoints = 8192
    private static let traceSec: Float = 0.040
    private static let triggerSearchSec: Float = 0.021
    private static let curvature: Float = 0.12

    private(set) var draw = SceneDraw(
        primitive: .lineStrip, vertexCount: 0, additive: true)

    private var energy = BandEnergy()
    private var stereoMode = false
    private var traceCount = 0

    private var vertices: MTLBuffer?
    var historyBuffer: MTLBuffer? { vertices }

    func prepare(device: MTLDevice) {
        vertices = device.makeBuffer(
            length: Self.maxPoints * 3 * MemoryLayout<Float>.stride,
            options: .storageModeShared)
    }

    func update(audio: AudioEngine, dt: Float) {
        energy.update(bands: audio.currentBands(), dt: dt)
        stereoMode = audio.hasStereoSource

        if stereoMode {
            updateStereo(audio: audio)
        } else {
            updateMono(audio: audio)
        }
        draw = SceneDraw(primitive: .lineStrip, vertexCount: traceCount, additive: true)
    }

    private func updateStereo(audio: AudioEngine) {
        let sampleRate = max(audio.sampleRate, 8000)
        let drawPoints = min(Int(Float(sampleRate) * Self.traceSec), Self.maxPoints)
        let speedScale = Float(sampleRate / 48_000)

        let totalPairs = drawPoints + Int(Float(sampleRate) * Self.triggerSearchSec) + 4
        let clamped = min(totalPairs, Self.maxPoints)
        var stereo = [Float](repeating: 0, count: clamped * 2)
        stereo.withUnsafeMutableBufferPointer { buf in
            audio.fillStereoWaveform(buf.baseAddress!, count: clamped)
        }

        let searchSpan = min(
            Int(Float(sampleRate) * Self.triggerSearchSec),
            clamped - drawPoints - 2
        )
        let base = max(0, clamped - drawPoints - max(searchSpan, 0))
        var startIndex = base
        if searchSpan > 0 {
            for i in base..<(base + searchSpan) {
                let left1 = stereo[i * 2]
                let left2 = stereo[(i + 1) * 2]
                if left1 <= 0 && left2 > 0 && stereo[(i + 2) * 2] > 0.01 {
                    startIndex = i
                    break
                }
            }
        }

        let limit = min(drawPoints, clamped - startIndex)
        guard limit > 1, let vertices else { traceCount = 0; return }
        let p = vertices.contents().bindMemory(to: Float.self, capacity: limit * 3)

        var prevX = stereo[startIndex * 2]
        var prevY = stereo[startIndex * 2 + 1]
        for i in 0..<limit {
            let x = stereo[(startIndex + i) * 2]
            let y = stereo[(startIndex + i) * 2 + 1]
            let dx = x - prevX
            let dy = y - prevY
            let o = i * 3
            p[o] = x
            p[o + 1] = y
            p[o + 2] = sqrtf(dx * dx + dy * dy) * speedScale
            prevX = x
            prevY = y
        }
        if limit > 1 { p[2] = p[5] }
        traceCount = limit
    }

    private func updateMono(audio: AudioEngine) {
        let sampleRate = max(audio.sampleRate, 8000)
        let drawPoints = min(Int(Float(sampleRate) * Self.traceSec), Self.maxPoints)
        let speedScale = Float(sampleRate / 48_000)

        var pcm = [Float](repeating: 0, count: drawPoints)
        pcm.withUnsafeMutableBufferPointer { buf in
            audio.fillWaveform(buf.baseAddress!, count: drawPoints)
        }

        guard drawPoints > 1, let vertices else { traceCount = 0; return }
        let p = vertices.contents().bindMemory(to: Float.self, capacity: drawPoints * 3)

        let step = 2.0 / Float(drawPoints - 1)
        var prevX: Float = -1.0
        var prevY: Float = pcm[0]
        for i in 0..<drawPoints {
            let x = Float(i) * step - 1.0
            let y = pcm[i]
            let dx = x - prevX
            let dy = y - prevY
            let o = i * 3
            p[o] = x
            p[o + 1] = y
            p[o + 2] = sqrtf(dx * dx + dy * dy) * speedScale
            prevX = x
            prevY = y
        }
        if drawPoints > 1 { p[2] = p[5] }
        traceCount = drawPoints
    }

    func writeData(into pointer: UnsafeMutableRawPointer) {
        let p = pointer.bindMemory(to: Float.self, capacity: 3)
        p[0] = energy.envelope
        p[1] = stereoMode ? 1.0 : 0.0
        p[2] = Float(traceCount)
    }

    var shaderSource: String {
        """
        \(Self.shaderPreamble)

        struct CrtData {
            float envelope;
            float stereo;
            float count;
        };

        struct VSOut {
            float4 position [[position]];
            float  t;
            float  intensity;
            float2 ndc;
        };

        vertex VSOut veloVertex(uint vid [[vertex_id]],
                                constant Uniforms &u [[buffer(0)]],
                                constant CrtData &s [[buffer(1)]],
                                device const float *pts [[buffer(2)]])
        {
            float aspect = u.resolution.x / max(u.resolution.y, 1.0);
            uint base = vid * 3;
            float2 pos = float2(pts[base], pts[base + 1]);
            float spd = pts[base + 2];

            // Burn-in protection orbit.
            float2 orbit = float2(
                sin(u.time * 0.31) + 0.5 * sin(u.time * 0.13 + 1.7),
                cos(u.time * 0.27) + 0.5 * cos(u.time * 0.19 + 0.9)
            ) * 0.005;

            // Square, always. X is left and Y is right, so both axes must share
            // a scale or the drawing in the signal comes out distorted.
            //
            // 0.86 looks conservative but is close to the ceiling: the barrel
            // below expands by (1 + 0.12 r²), which at a full-scale corner is
            // 24%, so 0.86 already reaches 1.013 there. Raising the fill crops
            // the corners of the artwork; the only way to gain real size is to
            // soften the curvature, which is the whole look of this scene.
            float2 p;
            if (s.stereo > 0.5) {
                p = float2(pos.x, pos.y);
                if (aspect > 1.0) p.x /= aspect;
                else               p.y *= aspect;
                p *= 0.86;
            } else {
                p = float2(pos.x, pos.y * 0.8);
                if (aspect > 1.0) p.x /= aspect;
                else               p.y *= aspect;
                p *= 0.86;
            }

            // Barrel curvature.
            float r2 = dot(p, p);
            p *= 1.0 + \(Self.curvature) * r2;

            VSOut out;
            out.position = float4(p + orbit, 0.0, 1.0);
            out.t = s.count > 1.0 ? float(vid) / (s.count - 1.0) : 0.0;
            out.ndc = p;

            // Velocity-modulated brightness: energy ~ 1 / speed.
            // Calibrated for per-sample distances at 48 kHz (~0.02–0.12).
            float b = 0.03 / (spd + 0.003);
            out.intensity = clamp(b, 0.15, 3.0);

            return out;
        }

        fragment float4 veloFragment(VSOut in [[stage_in]],
                                     constant Uniforms &u [[buffer(0)]],
                                     constant CrtData &s [[buffer(1)]])
        {
            // P1 phosphor green.
            float3 phosphor = float3(0.30, 1.0, 0.45);

            // Persistence: trailing beam fades.
            float age = 1.0 - in.t;
            float persistence = exp(-age * 2.5);

            float energy = in.intensity * persistence;
            // White-hot core where the beam dwells longest.
            float3 col = mix(phosphor, float3(1.0), clamp(energy - 1.5, 0.0, 1.0));
            col *= energy * 3.5;

            // Scanline modulation: subtle brightness bands from the raster.
            float scanline = 0.85 + 0.15 * sin(in.position.y * 3.14159 * 1.5);
            col *= scanline;

            // Glass vignette: tighter to show the tube edge.
            float r = length(in.ndc);
            float vig = 1.0 - smoothstep(0.55, 0.95, r);
            col *= vig;

            // Edge chromatic aberration: slight red/blue fringe at the tube rim.
            float fringe = smoothstep(0.3, 0.8, r);
            col.r *= 1.0 + fringe * 0.15;
            col.b *= 1.0 - fringe * 0.10;

            col = themeGrade(col, u) * u.dim;
            return float4(col, 1.0);
        }
        """
    }
}
