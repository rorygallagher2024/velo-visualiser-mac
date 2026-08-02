import Foundation
import Metal

/// "Phase Scope" — ported from Android.
///
/// A 3D oscilloscope that plots each PCM sample as a point in phase space:
/// `(s[i], s[i+tau], s[i+2*tau])`, a time-delay embedding of the raw waveform.
/// The result is a single glowing beam that traces a living space-curve:
/// sustained notes draw clean rotating loops, transients flare it open, silence
/// collapses it to a point.
///
/// On Android this draws as GL_LINE_STRIP; on Metal we use closely-packed point
/// sprites along the same curve, which at high DPI merge into a continuous
/// glowing beam. The auto-rotating 3D camera reveals the structure's depth.
final class PhaseScopeScene: VeloScene {

    let name = "Phase Scope"

    private static let pcmWindow = 1024
    private static let tau = 48
    private static let vertexCount = pcmWindow - 2 * tau

    let draw = SceneDraw.points(PhaseScopeScene.vertexCount)

    private var energy = BandEnergy()
    private var gain: Float = 20
    private var peak: Float = 0
    private static let agcTarget: Float = 5.5
    private var stereoMode = false

    private var particles: MTLBuffer?
    var historyBuffer: MTLBuffer? { particles }

    func prepare(device: MTLDevice) {
        particles = device.makeBuffer(
            length: Self.vertexCount * 4 * MemoryLayout<Float>.stride,
            options: .storageModeShared)
    }

    func update(audio: AudioEngine, dt: Float) {
        energy.update(bands: audio.currentBands(), dt: dt)
        stereoMode = audio.hasStereoSource

        if stereoMode {
            updateStereoXY(audio: audio)
        } else {
            updateTimeDelay(audio: audio)
        }
    }

    private func updateTimeDelay(audio: AudioEngine) {
        var pcm = [Float](repeating: 0, count: Self.pcmWindow + 2 * Self.tau)
        pcm.withUnsafeMutableBufferPointer { buf in
            audio.fillWaveform(buf.baseAddress!, count: buf.count)
        }

        updateGain(pcm: pcm)

        guard let particles else { return }
        let p = particles.contents().bindMemory(
            to: Float.self, capacity: Self.vertexCount * 4)
        for i in 0..<Self.vertexCount {
            let o = i * 4
            p[o]     = softClip(pcm[i])
            p[o + 1] = softClip(pcm[i + Self.tau])
            p[o + 2] = softClip(pcm[i + 2 * Self.tau])
            p[o + 3] = Float(i) / Float(Self.vertexCount - 1)
        }
    }

    private func updateStereoXY(audio: AudioEngine) {
        var stereo = [Float](repeating: 0, count: Self.vertexCount * 2)
        stereo.withUnsafeMutableBufferPointer { buf in
            audio.fillStereoWaveform(buf.baseAddress!, count: Self.vertexCount)
        }

        var pk: Float = 0
        for s in stereo { pk = max(pk, abs(s)) }
        peak = pk
        let target = Self.agcTarget / max(pk, 0.0001)
        let clamped = min(target, 80.0)
        let rate: Float = clamped < gain ? 0.15 : 0.08
        gain += (clamped - gain) * rate

        guard let particles else { return }
        let p = particles.contents().bindMemory(
            to: Float.self, capacity: Self.vertexCount * 4)
        for i in 0..<Self.vertexCount {
            let o = i * 4
            let l = stereo[i * 2]
            let r = stereo[i * 2 + 1]
            p[o]     = softClip(l)
            p[o + 1] = softClip(r)
            p[o + 2] = 0
            p[o + 3] = Float(i) / Float(Self.vertexCount - 1)
        }
    }

    func writeData(into pointer: UnsafeMutableRawPointer) {
        let p = pointer.bindMemory(to: Float.self, capacity: 2)
        p[0] = energy.envelope
        p[1] = stereoMode ? 1.0 : 0.0
    }

    private func updateGain(pcm: [Float]) {
        var pk: Float = 0
        for s in pcm { pk = max(pk, abs(s)) }
        peak = pk

        let target = Self.agcTarget / max(pk, 0.0001)
        let clamped = min(target, 80.0)
        let rate: Float = clamped < gain ? 0.15 : 0.08
        gain += (clamped - gain) * rate
    }

    private func softClip(_ s: Float) -> Float {
        let g = s * gain
        return g / (1 + abs(g))
    }

    var shaderSource: String {
        """
        \(Self.shaderPreamble)

        struct PhaseData {
            float envelope;
            float stereo;
        };

        constant uint VCOUNT = \(Self.vertexCount);

        struct VSOut {
            float4 position [[position]];
            float  size     [[point_size]];
            float  t;
            float  amp;
            float  depth;
        };

        static inline float3 palette(float t) {
            return 0.5 + 0.5 * cos(6.28318 * (t + float3(0.0, 0.33, 0.67)));
        }

        vertex VSOut veloVertex(uint vid [[vertex_id]],
                                constant Uniforms &u [[buffer(0)]],
                                constant PhaseData &s [[buffer(1)]],
                                device const float4 *pts [[buffer(2)]])
        {
            float aspect = u.resolution.x / max(u.resolution.y, 1.0);
            float dpi = max(u.resolution.y / 1080.0, 1.0);

            float4 d = pts[vid];
            float3 p = d.xyz;

            float w;
            float2 proj;

            if (s.stereo > 0.5) {
                // Stereo XY mode: L->X, R->Y, flat 2D Lissajous.
                proj = float2(p.x / aspect, p.y) * 0.78;
                w = 1.0;
            } else {
                // Time-delay embedding: 3D with auto-rotation.
                float ya = u.time * 0.25;
                float pa = 0.45 + 0.30 * sin(u.time * 0.13);
                float cy = cos(ya), sy = sin(ya);
                p = float3(cy * p.x + sy * p.z, p.y, -sy * p.x + cy * p.z);
                float cp = cos(pa), sp = sin(pa);
                p = float3(p.x, cp * p.y - sp * p.z, sp * p.y + cp * p.z);

                w = 3.0 / (3.0 - p.z);
                proj = float2(p.x / aspect, p.y) * w * 0.78;
            }

            VSOut out;
            out.position = float4(proj, 0.0, 1.0);
            out.size = max(dpi * 2.5 * w, 1.5);
            out.t = d.w;
            out.amp = length(d.xyz);
            out.depth = s.stereo > 0.5 ? 0.75 : clamp((p.z + 1.0) * 0.5, 0.0, 1.0);
            return out;
        }

        fragment float4 veloFragment(VSOut in [[stage_in]],
                                     float2 pc [[point_coord]],
                                     constant Uniforms &u [[buffer(0)]],
                                     constant PhaseData &s [[buffer(1)]])
        {
            float2 c = pc * 2.0 - 1.0;
            float d2 = dot(c, c);
            if (d2 > 1.0) discard_fragment();
            float glow = exp(-d2 * 2.5);

            float h = in.t + u.time * 0.04;
            float3 col = palette(h);

            float bright = (0.35 + in.amp * 1.3) * (0.8 + s.envelope * 1.6);
            float depthCue = mix(0.55, 1.25, in.depth);
            col *= bright * depthCue * glow;
            col *= 1.4 + in.amp * 1.6;
            col = themeGrade(col, u) * u.dim;

            return float4(col, 1.0);
        }
        """
    }
}
