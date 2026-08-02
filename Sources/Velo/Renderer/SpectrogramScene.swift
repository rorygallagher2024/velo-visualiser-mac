import Foundation
import Metal

/// "Spectrogram" — ported from Android.
///
/// A scrolling time-frequency heatmap: frequency up the screen, time across it,
/// magnitude as colour. The one visual with memory, so you watch a beat's
/// structure scroll away rather than only seeing the present.
///
/// The colour ramp is inferno rather than a hue sweep, and that is the whole
/// design. Equal loudness steps read as equal colour steps, and quiet detail
/// gets a hue of its own (violet) instead of sinking into murky dark red.
///
/// The only scene here that keeps history of its own. It is a ring: each frame
/// writes ONE new column at a moving index, and the shader reads with a rolling
/// offset so it appears to scroll. Handing over the whole history every frame
/// would be 320 KB at 120 Hz to deliver one column of new information.
final class SpectrogramScene: VeloScene {

    static let bins = AudioEngine.binCount
    /// About five seconds of history at 120 fps.
    static let cols = 640

    let name = "Spectrogram"

    private var writeCol: Float = 0
    private let colsPerSecond: Float = 120.0
    private var history: MTLBuffer?

    var historyBuffer: MTLBuffer? { history }

    func prepare(device: MTLDevice) {
        // Shared storage: the scene writes one column straight into the memory
        // the GPU reads. The GPU may be reading an older frame while that
        // happens, so at worst one column of one frame is half updated, which
        // is one column out of 640 and invisible.
        let bytes = Self.cols * Self.bins * MemoryLayout<Float>.stride
        history = device.makeBuffer(length: bytes, options: .storageModeShared)
        if let history { memset(history.contents(), 0, bytes) }
    }

    func update(audio: AudioEngine, dt: Float) {
        let bins = audio.currentBins()
        guard bins.count == Self.bins, let history else { return }

        // Time-based advancement so scroll speed is independent of framerate
        let advance = dt * colsPerSecond
        let oldInt = Int(writeCol)
        writeCol = (writeCol + advance).truncatingRemainder(dividingBy: Float(Self.cols))
        let newInt = Int(writeCol)
        
        // Find how many discrete columns we crossed
        var crossed = newInt - oldInt
        if crossed < 0 { crossed += Self.cols }
        
        if crossed > 0 {
            for offset in 0..<crossed {
                let targetCol = (oldInt + 1 + offset) % Self.cols
                let dst = history.contents()
                    .advanced(by: targetCol * Self.bins * MemoryLayout<Float>.stride)
                    .assumingMemoryBound(to: Float.self)
                for i in 0..<Self.bins { dst[i] = bins[i] }
            }
        }
    }

    func writeData(into pointer: UnsafeMutableRawPointer) {
        var packed = SIMD2<Float>(writeCol, Float(Self.cols))
        pointer.copyMemory(from: &packed, byteCount: MemoryLayout<SIMD2<Float>>.size)
    }

    var shaderSource: String {
        """
        \(Self.shaderPreamble)

        struct Scroll { float write; float cols; };

        \(Self.fullscreenVertexShader)
        \(Self.glslMod)

        constant float BIN_ROWS = float(\(Self.bins));

        // Perceptual inferno ramp, a polynomial fit of the matplotlib colormap:
        // black to deep violet to crimson to orange to pale yellow. max() guards
        // the fit's small negative overshoots, so no negative light is written.
        static inline float3 inferno(float t) {
            t = clamp(t, 0.0, 1.0);
            const float3 c0 = float3(0.00022, 0.00165, -0.01948);
            const float3 c1 = float3(0.10651, 0.56396, 3.93271);
            const float3 c2 = float3(11.60249, -3.97285, -15.94239);
            const float3 c3 = float3(-41.70400, 17.43640, 44.35415);
            const float3 c4 = float3(77.16294, -33.40236, -81.80731);
            const float3 c5 = float3(-71.31943, 32.62606, 73.20952);
            const float3 c6 = float3(25.13113, -12.24267, -23.07033);
            float3 c = c0 + t * (c1 + t * (c2 + t * (c3 + t * (c4 + t * (c5 + t * c6)))));
            return max(c, 0.0);
        }

        fragment float4 veloFragment(VSOut in [[stage_in]],
                                     constant Uniforms &u [[buffer(0)]],
                                     constant Scroll &s [[buffer(1)]],
                                     device const float *history [[buffer(2)]])
        {
            constexpr int BINS = \(Self.bins);

            float2 uv = float2(in.position.x, u.resolution.y - in.position.y) / u.resolution;

            // Newest column on the right, scrolling left over time.
            float col = s.write - (1.0 - uv.x) * (s.cols - 1.0);
            // Discrete columns, never blended. The newest column sits beside
            // the oldest across the ring seam, and interpolating there would
            // smear five seconds ago into now. It also keeps the time axis an
            // honest read.
            int colIndex = int(floor(gmod(col, s.cols)));

            // Frequency axis: interpolate between bins, with a smoothstep on
            // the fraction so gradients are kink-free rather than tent-shaped.
            float fy = uv.y * BIN_ROWS - 0.5;
            float row = floor(fy);
            float fr = fy - row;
            fr = fr * fr * (3.0 - 2.0 * fr);
            int r0 = clamp(int(row), 0, BINS - 1);
            int r1 = clamp(int(row) + 1, 0, BINS - 1);
            int base = colIndex * BINS;
            float m = mix(history[base + r0], history[base + r1], fr);

            // The ramp carries its own luminance design, so there is no
            // brightness multiplier below the knee. Only the loudest material
            // is driven past 1.0.
            float3 c = inferno(m) * (1.0 + 1.3 * smoothstep(0.82, 1.0, m));
            return float4(themeGrade(c, u) * u.dim, 1.0);
        }
        """
    }
}
