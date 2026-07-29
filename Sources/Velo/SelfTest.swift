import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

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
/// Run with `VELO_SELFTEST=1`. Two optional knobs:
///
/// * `VELO_SELFTEST_SIZE=3840x2160` renders at another size. Fragment cost is
///   very nearly linear in pixel count, so a figure measured at 1080p says
///   little about a scene running fullscreen on a 4K panel — a Starscape that
///   looked comfortable at 5 ms here was really costing four times that.
/// * `VELO_SELFTEST_DUMP=<dir>` writes each scene's frame out as a PNG. The
///   statistics below say a scene is not blank and not deaf; they cannot say it
///   is not *ugly*. A star field that aliases into hard blocks scores exactly
///   as well as one that does not, so the only way to catch that without a
///   person at the screen is to look at the pixels.
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
              let renderer = Renderer(device: device, beatBus: BeatBus()),
              let quiet = Renderer(device: device, beatBus: BeatBus())
        else {
            print("[selftest] no Metal device")
            exit(1)
        }

        // Fixed for the run, and stated in the output. Window size is the single
        // biggest input to fragment cost, and a table measured across a resize
        // is worthless: one run here reported 8.1 Mpx at the top and 1.7 Mpx at
        // the bottom because the window was dragged mid-measurement.
        let (width, height) = requestedSize()
        let dumpDirectory = ProcessInfo.processInfo.environment["VELO_SELFTEST_DUMP"]
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

            if let dumpDirectory {
                dump(target, width: width, height: height, directory: dumpDirectory,
                     file: String(format: "%02d-%@.png", index, name))
            }

            // Scaled to the render height. A one-pixel trace covers 1/height of
            // the frame however tall it is, so a fixed floor calls the Raw
            // Oscilloscope blank at 4K purely for being rendered larger.
            let floorCoverage = minimumCoverage * 1080 / Double(height)

            var verdict = "ok"
            if coverage < floorCoverage { verdict = "BLANK"; failures += 1 }
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

    /// `VELO_SELFTEST_SIZE=WxH`, or 1080p.
    private static func requestedSize() -> (Int, Int) {
        guard let raw = ProcessInfo.processInfo.environment["VELO_SELFTEST_SIZE"] else {
            return (1920, 1080)
        }
        let parts = raw.lowercased().split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return (1920, 1080) }
        return (parts[0], parts[1])
    }

    /// Write one render out as a PNG, so a person (or a later session) can look
    /// at what the numbers only summarise.
    private static func dump(
        _ texture: MTLTexture, width: Int, height: Int, directory: String, file: String
    ) {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!, bytesPerRow: width * 4,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }

        // bgra8Unorm is ARGB read little-endian, and the alpha carries nothing
        // here, so it is declared as skipped rather than premultiplied.
        let info = CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.noneSkipFirst.rawValue
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return }

        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: directory).appendingPathComponent(file) as CFURL
        guard let destination = CGImageDestinationCreateWithURL(
            url, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
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
