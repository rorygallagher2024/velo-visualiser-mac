import AppKit

/// A display the canvas can be sent to.
///
/// Identified by name rather than by `CGDirectDisplayID`. The ID is reassigned
/// when a display is unplugged and plugged back in, so the projector that was
/// the output before the set would come back as a different display and the
/// remembered choice would be silently dropped — precisely the moment it needs
/// to hold. Names survive a reconnect.
///
/// Two identical panels genuinely do report the same name, so the second one is
/// disambiguated with a suffix and the pairing then rests on `NSScreen.screens`
/// order. That order is stable while nothing is replugged, which is the same
/// trade the audio device picker already makes.
struct DisplayTarget: Identifiable, Hashable {
    /// Disambiguated: unique across the returned list, and what gets persisted.
    let name: String
    let isMain: Bool
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshHz: Int

    var id: String { name }

    /// "3840 × 2160 · 60 Hz · Main"
    var detail: String {
        var parts = ["\(pixelWidth) \u{00D7} \(pixelHeight)"]
        if refreshHz > 0 { parts.append("\(refreshHz) Hz") }
        if isMain { parts.append("Main") }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// Every attached display, in `NSScreen.screens` order.
    static func all() -> [DisplayTarget] {
        var seen: [String: Int] = [:]
        return NSScreen.screens.map { screen in
            let base = screen.localizedName
            let count = (seen[base] ?? 0) + 1
            seen[base] = count
            let scale = screen.backingScaleFactor
            return DisplayTarget(
                name: count == 1 ? base : "\(base) (\(count))",
                isMain: screen == NSScreen.main,
                pixelWidth: Int((screen.frame.width * scale).rounded()),
                pixelHeight: Int((screen.frame.height * scale).rounded()),
                refreshHz: screen.maximumFramesPerSecond)
        }
    }

    /// The screen a persisted name refers to, or nil if it is not attached.
    ///
    /// Re-derives the list so the disambiguating suffixes match the ones that
    /// were handed out; `all()` maps `NSScreen.screens` one to one, so the two
    /// stay in step.
    static func screen(named name: String) -> NSScreen? {
        zip(all(), NSScreen.screens).first { $0.0.name == name }?.1
    }
}
