import SwiftUI

/// One reading of how the app is doing, as of the last sampling period.
struct PerfSnapshot: Sendable, Equatable {
    var fps: Double = 0
    var worstMs: Double = 0
    var gpuMs: Double = 0
    var encodeMs: Double = 0
    var waitDrawableMs: Double = 0
    var waitSemaphoreMs: Double = 0
    var dropped = 0
    var hitches = 0
    var pixels = 0
    /// What the DISPLAY is doing, measured from the display link rather than
    /// assumed. A ProMotion panel is adaptive, so the refresh rate is a fact to
    /// be checked and not a constant: an app rendering happily at its own pace
    /// into a panel that has quietly dropped to 40 Hz looks identical to an app
    /// that is slow.
    var displayHz = 0.0
}

/// Hands the render thread's stats to the view layer.
///
/// A plain reference type on purpose. The obvious route was a SwiftUI `@State`
/// assigned from `makeNSView`, but that runs DURING a view update, where
/// SwiftUI discards the write. The overlay read a default snapshot forever and
/// showed a confident 0.0 fps. A box can be filled whenever the view is built,
/// because nothing about it is part of the update cycle.
final class StatsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: FrameStats?
    var stats: FrameStats? {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

/// The diagnostics overlay, modelled on the Android app's.
///
/// Off by default and on a key, because the canvas is meant to be pure output:
/// anything drawn over it lands in whatever is capturing the window. This is a
/// tool for working out why something is wrong, not part of the instrument.
///
/// What it reports is chosen to distinguish faults that look identical from the
/// outside. A low frame rate with the GPU idle is a stall; with the GPU busy it
/// is fill cost, and the pixel count says which. Hitches separate one long
/// freeze from a steady drizzle of short ones. And the audio line exists
/// because "the visual is not moving" and "the visual is not receiving
/// anything" are the same picture.
struct PerfOverlay: View {
    let snapshot: PerfSnapshot
    let scene: String
    let audio: AudioStatus
    let hdr: Bool
    var syphon: Bool = false
    var toneActive: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(String(format: "%.1f", snapshot.fps))
                    .font(Velo.spectacle(38))
                    .foregroundStyle(fpsColour)
                    .monospacedDigit()
                Text("FPS").font(label).foregroundStyle(.white.opacity(0.35))
                    .tracking(1.4)
                Spacer(minLength: 12)
                Text(megapixels).font(label).foregroundStyle(.white.opacity(0.35))
            }
            .padding(.bottom, 8)

            row("gpu", ms(snapshot.gpuMs))
            row("encode", ms(snapshot.encodeMs))
            row("wait", ms(snapshot.waitDrawableMs))
            // Waiting on our own frame slots rather than on the display means
            // the GPU is behind, which is a different problem from vsync.
            if snapshot.waitSemaphoreMs > 0.5 {
                row("wait slot", ms(snapshot.waitSemaphoreMs), warn: true)
            }
            row("worst", ms(snapshot.worstMs), warn: snapshot.worstMs > 33)
            if snapshot.hitches > 0 { row("hitches", "\(snapshot.hitches)", warn: true) }
            if snapshot.dropped > 0 { row("dropped", "\(snapshot.dropped)", warn: true) }

            divider()
            row("visual", scene, mono: false)
            row("range", hdr ? "HDR" : "SDR")
            row("refresh", displayRate)
            row("device", MachineInfo.chip)
            if syphon { row("syphon", "active") }

            divider()
            row("input", toneActive ? "test tone" : audio.device, mono: false)
            if !toneActive { row("format", audio.format) }
            row("level", audio.silent ? "silent" : meter)
            if LinkSync.enabled {
                let peers = LinkSync.statusPeers
                let bpm = LinkSync.statusBpm
                row("link", peers > 0
                    ? String(format: "%d peer%@ · %.0f bpm", peers, peers == 1 ? "" : "s", bpm)
                    : "searching")
            } else if FourFourSync.enabled {
                let bpm = FourFourSync.statusBpm
                row("4/4", bpm > 0
                    ? String(format: "LOCKED · %.0f bpm", bpm)
                    : "searching")
            }
        }
        .padding(14)
        .frame(width: 296, alignment: .leading)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.10), lineWidth: 1)
        )
    }

    private var label: Font { Velo.label(9.5) }
    private var value: Font { Velo.readout(11) }

    /// FPS colour relative to whatever the display is actually running.
    /// White when keeping up, amber when dropping frames, red below half rate.
    private var fpsColour: Color {
        let target = max(snapshot.displayHz, 60)
        if snapshot.fps >= target * 0.92 { return .white }
        if snapshot.fps >= target * 0.5  { return Color(red: 1.0, green: 0.75, blue: 0.35) }
        return Color(red: 1.0, green: 0.45, blue: 0.40)
    }

    /// The panel's measured refresh rate.
    private var displayRate: String {
        snapshot.displayHz == 0 ? "" : String(format: "%.0f Hz", snapshot.displayHz)
    }

    private var megapixels: String {
        snapshot.pixels == 0 ? "" : String(format: "%.1f Mpx", Double(snapshot.pixels) / 1e6)
    }

    private func ms(_ v: Double) -> String { String(format: "%.2f ms", v) }

    /// The number, then five blocks. The blocks answer "is anything arriving"
    /// at a glance; the dB figure is what you actually need when the answer is
    /// "yes, but not enough".
    private var meter: String {
        let filled = min(Int((audio.levelFraction * 5).rounded(.up)), 5)
        let blocks = String(repeating: "▮", count: filled)
                   + String(repeating: "▯", count: 5 - filled)
        return String(format: "%+.0f dB %@", audio.levelDb, blocks)
    }

    private func row(
        _ name: String, _ text: String, warn: Bool = false, mono: Bool = true
    ) -> some View {
        HStack(spacing: 8) {
            Text(name.uppercased())
                .font(label)
                .tracking(0.9)
                .foregroundStyle(.white.opacity(0.35))
                .frame(width: 66, alignment: .leading)
            Text(text)
                .font(mono ? value : Velo.body(11))
                .foregroundStyle(warn ? Color(red: 1.0, green: 0.75, blue: 0.35) : .white)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
    }

    private func divider() -> some View {
        Rectangle()
            .fill(.white.opacity(0.10))
            .frame(height: 1)
            .padding(.vertical, 7)
    }
}

/// Reads the chip name once and holds it for the overlay.
enum MachineInfo {
    static let chip: String = {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "Apple Silicon" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        let raw = String(decoding: buf.prefix(while: { $0 != 0 }).map(UInt8.init), as: UTF8.self)
        // "Apple M4 Pro" is more useful than the full Intel-style string.
        return raw.hasPrefix("Apple") ? raw : String(raw.prefix(40))
    }()
}
