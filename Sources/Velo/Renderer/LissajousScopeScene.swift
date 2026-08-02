import Foundation
import Metal

/// "Lissajous Scope" — a clean stereo XY oscilloscope.
///
/// Ported from Android. Left audio drives X, Right drives Y, traced as a
/// single continuous glowing line. No velocity modulation, no barrel curvature,
/// no vignette — just the raw beam with phosphor persistence. The simplest
/// honest readout of a stereo signal.
///
/// Falls back to a mono time-base display when no stereo source is active.
final class LissajousScopeScene: VeloScene {

    let name = "Lissajous Scope"

    private static let maxPoints = 8192
    private static let traceSec: Float = 0.040
    private static let triggerSearchSec: Float = 0.021

    private(set) var draw = SceneDraw(
        primitive: .lineStrip, vertexCount: 0, additive: true)

    private var energy = BandEnergy()
    private var stereoMode = false
    private var traceCount = 0

    private var vertices: MTLBuffer?
    var historyBuffer: MTLBuffer? { vertices }

    func prepare(device: MTLDevice) {
        vertices = device.makeBuffer(
            length: Self.maxPoints * 2 * MemoryLayout<Float>.stride,
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
        let p = vertices.contents().bindMemory(to: Float.self, capacity: limit * 2)

        for i in 0..<limit {
            p[i * 2]     = stereo[(startIndex + i) * 2]
            p[i * 2 + 1] = stereo[(startIndex + i) * 2 + 1]
        }
        traceCount = limit
    }

    private func updateMono(audio: AudioEngine) {
        let sampleRate = max(audio.sampleRate, 8000)
        let drawPoints = min(Int(Float(sampleRate) * Self.traceSec), Self.maxPoints)

        var pcm = [Float](repeating: 0, count: drawPoints)
        pcm.withUnsafeMutableBufferPointer { buf in
            audio.fillWaveform(buf.baseAddress!, count: drawPoints)
        }

        guard drawPoints > 1, let vertices else { traceCount = 0; return }
        let p = vertices.contents().bindMemory(to: Float.self, capacity: drawPoints * 2)

        for i in 0..<drawPoints {
            let x = Float(i) / Float(drawPoints - 1) * 2.0 - 1.0
            p[i * 2]     = x
            p[i * 2 + 1] = pcm[i]
        }
        traceCount = drawPoints
    }

    func writeData(into pointer: UnsafeMutableRawPointer) {
        let p = pointer.bindMemory(to: Float.self, capacity: 2)
        p[0] = stereoMode ? 1.0 : 0.0
        p[1] = Float(traceCount)
    }

    var shaderSource: String {
        """
        \(Self.shaderPreamble)

        struct ScopeData {
            float stereo;
            float count;
        };

        struct VSOut {
            float4 position [[position]];
            float  t;
        };

        vertex VSOut veloVertex(uint vid [[vertex_id]],
                                constant Uniforms &u [[buffer(0)]],
                                constant ScopeData &s [[buffer(1)]],
                                device const float *pts [[buffer(2)]])
        {
            float aspect = u.resolution.x / max(u.resolution.y, 1.0);

            float2 pos = float2(pts[vid * 2], pts[vid * 2 + 1]);

            // Burn-in protection orbit.
            float2 orbit = float2(
                sin(u.time * 0.31) + 0.5 * sin(u.time * 0.13 + 1.7),
                cos(u.time * 0.27) + 0.5 * cos(u.time * 0.19 + 0.9)
            ) * 0.005;

            float2 p = pos;
            if (aspect > 1.0) p.x /= aspect;
            else               p.y *= aspect;
            p *= 0.9;

            VSOut out;
            out.position = float4(p + orbit, 0.0, 1.0);
            out.t = s.count > 1.0 ? float(vid) / (s.count - 1.0) : 0.0;
            return out;
        }

        fragment float4 veloFragment(VSOut in [[stage_in]],
                                     constant Uniforms &u [[buffer(0)]],
                                     constant ScopeData &s [[buffer(1)]])
        {
            // Classic oscilloscope phosphor green.
            float3 phosphor = float3(0.45, 1.0, 0.65);

            // Persistence: trailing beam fades.
            float age = 1.0 - in.t;
            float intensity = exp(-age * 3.5);

            // Bright enough to reach into HDR headroom on EDR displays.
            float3 col = phosphor * intensity * 3.2;

            col = themeGrade(col, u) * u.dim;
            return float4(col, 1.0);
        }
        """
    }
}
