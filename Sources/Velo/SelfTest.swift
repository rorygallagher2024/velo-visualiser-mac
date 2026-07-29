import Foundation
import Metal

/// Renders every visual offscreen and looks at the pixels.
///
/// This exists because the previous check did not. Confirming that a shader
/// compiles and that the frame rate holds proves nothing about whether anything
/// was drawn: a scene that outputs pure black passes both, at a very good frame
/// rate. One shipped that way.
///
/// So this draws each scene into an offscreen texture with a known signal in the
/// ring, reads the pixels back, and reports what is actually on them. A visual
/// can still be ugly or wrong, which no automated check will catch, but it can
/// no longer be *empty* without saying so.
///
/// Run with `VELO_SELFTEST=1`.
enum SelfTest {

    /// Anything below this fraction of lit pixels is reported as a failure.
    /// Deliberately low: an oscilloscope trace is a thin line on a black field
    /// and legitimately covers well under one percent.
    private static let minimumCoverage = 0.001

    /// Mean absolute luminance difference between the signal and silence
    /// renders, below which a scene is not really listening.
    private static let minimumReaction = 0.0005

    static func run() -> Never {
        // Two independent renderers, so each scene exists twice with its own
        // state: one fed signal, one fed silence, rendered at identical times.
        // Comparing them isolates audio reactivity from animation, and catches
        // the failure "draws something" cannot: a scene that renders happily
        // and ignores the audio completely.
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = Renderer(device: device),
              let quiet = Renderer(device: device)
        else {
            print("[selftest] no Metal device")
            exit(1)
        }

        // Fixed, and stated in the output. Window size is the single biggest
        // input to fragment cost, and a table measured across a resize is
        // worthless: one run here reported 8.1 Mpx at the top and 1.7 Mpx at
        // the bottom because the window was dragged mid-measurement.
        let width = 1920, height = 1080
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: descriptor),
              let quietTarget = device.makeTexture(descriptor: descriptor)
        else { exit(1) }

        let audio = AudioEngine()
        audio.injectTestSignal()
        let silence = AudioEngine()

        var failures = 0
        print("[selftest] \(SceneCatalog.names.count) visuals at \(width)x\(height), \(String(format: "%.1f", Double(width * height) / 1e6)) Mpx")

        for (index, name) in SceneCatalog.names.enumerated() {
            renderer.selectScene(index)
            quiet.selectScene(index)

            // Several frames: scenes with ballistics start at zero and rise, and
            // one with history needs a few columns before it has anything to
            // show. Judging any of them on frame one would be unfair.
            var gpu: [Double] = []
            for frame in 0..<45 {
                audio.injectTestSignal()
                let t = renderer.renderOffscreen(
                    into: target, audio: audio, time: Float(frame) * 0.05)
                if frame >= 15 { gpu.append(t) }   // skip warm-up
                quiet.renderOffscreen(into: quietTarget, audio: silence,
                                      time: Float(frame) * 0.05)
            }
            let meanGPU = gpu.isEmpty ? 0 : gpu.reduce(0, +) / Double(gpu.count) * 1000

            let (coverage, mean, _) = inspect(target, width: width, height: height)
            let reacts = difference(target, quietTarget, width: width, height: height)

            var verdict = "ok"
            if coverage < minimumCoverage { verdict = "BLANK"; failures += 1 }
            else if reacts < minimumReaction { verdict = "DEAF"; failures += 1 }

            print(String(format: "[selftest] %-19s lit %6.2f%%  mean %.4f  reacts %.4f  gpu %5.2f ms  %@",
                         (name as NSString).utf8String!, coverage * 100, mean, reacts,
                         meanGPU, verdict))
        }

        print("[selftest] " + (failures == 0
            ? "all visuals draw, and all react to audio"
            : "\(failures) failed"))
        exit(failures == 0 ? 0 : 1)
    }

    /// Mean absolute luminance difference between two renders.
    private static func difference(
        _ a: MTLTexture, _ b: MTLTexture, width: Int, height: Int
    ) -> Double {
        let count = width * height
        var pa = [UInt8](repeating: 0, count: count * 4)
        var pb = [UInt8](repeating: 0, count: count * 4)
        pa.withUnsafeMutableBytes { raw in
            a.getBytes(raw.baseAddress!, bytesPerRow: width * 4,
                       from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        pb.withUnsafeMutableBytes { raw in
            b.getBytes(raw.baseAddress!, bytesPerRow: width * 4,
                       from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        var total = 0.0
        for i in stride(from: 0, to: count * 4, by: 4) {
            total += abs(Double(pa[i]) - Double(pb[i])) / 255
            total += abs(Double(pa[i + 1]) - Double(pb[i + 1])) / 255
            total += abs(Double(pa[i + 2]) - Double(pb[i + 2])) / 255
        }
        return total / Double(count * 3)
    }

    /// Fraction of lit pixels, mean luminance, and peak luminance.
    private static func inspect(
        _ texture: MTLTexture, width: Int, height: Int
    ) -> (coverage: Double, mean: Double, peak: Double) {
        let count = width * height
        var pixels = [UInt8](repeating: 0, count: count * 4)
        pixels.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!,
                             bytesPerRow: width * 4,
                             from: MTLRegionMake2D(0, 0, width, height),
                             mipmapLevel: 0)
        }

        var lit = 0
        var total = 0.0
        var peak = 0.0
        for i in stride(from: 0, to: count * 4, by: 4) {
            // bgra8Unorm, so blue is first. Rec. 709 luma.
            let b = Double(pixels[i]) / 255
            let g = Double(pixels[i + 1]) / 255
            let r = Double(pixels[i + 2]) / 255
            let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
            total += y
            peak = max(peak, y)
            // Above the 8-bit floor, so a scene that dithers a black background
            // is not counted as lit.
            if y > 2.0 / 255.0 { lit += 1 }
        }
        return (Double(lit) / Double(count), total / Double(count), peak)
    }
}
