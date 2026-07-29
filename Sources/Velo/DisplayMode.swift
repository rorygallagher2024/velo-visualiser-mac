import AppKit
import CoreGraphics

/// Switches the display to its native (unscaled) mode for fullscreen, and puts
/// it back afterwards.
///
/// A scaled desktop resolution means macOS renders to a framebuffer larger than
/// the panel and downsamples every frame — on this machine, 3600x2338 down to a
/// 3024x1964 panel. Games avoid that by taking the display mode themselves,
/// which is exactly what this does: `CGDisplaySetDisplayMode` is the public,
/// long-standing API for it.
///
/// The original mode is captured before the switch and restored on exit, on
/// quit, and on crash-adjacent paths, because leaving somebody's desktop in a
/// resolution they did not choose is a genuinely bad failure mode.
// Main-actor isolated: every entry point runs from a window notification on the
// main queue, and Swift 6 is right to refuse shared mutable state without that
// being said out loud.
@MainActor
enum DisplayMode {

    private static var savedMode: CGDisplayMode?
    private static var savedDisplay: CGDirectDisplayID?

    /// macOS marks the panel's true native timing with this bit in `ioFlags`.
    /// Without it there is no reliable way to tell "native" from "a scaled mode
    /// that happens to be large" — 3600x2338 is bigger than native here, and
    /// picking by size alone would choose exactly the wrong one.
    private static let nativeFlag: UInt32 = 0x0200_0000

    static func displayID(for screen: NSScreen?) -> CGDirectDisplayID? {
        guard let screen else { return nil }
        return screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? CGDirectDisplayID
    }

    /// The native-timing mode at the highest refresh rate the panel offers.
    static func nativeMode(for display: CGDirectDisplayID) -> CGDisplayMode? {
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode]
        else { return nil }
        return modes
            .filter { $0.ioFlags & nativeFlag != 0 && $0.isUsableForDesktopGUI() }
            // Prefer the HiDPI variant: same panel pixels, half the logical
            // size, so everything on screen stays a sane size.
            .sorted { a, b in
                if a.refreshRate != b.refreshRate { return a.refreshRate > b.refreshRate }
                return a.width < b.width
            }
            .first
    }

    @discardableResult
    static func engageNative(on screen: NSScreen?, verbose: Bool = false) -> Bool {
        guard savedMode == nil,
              let display = displayID(for: screen),
              let current = CGDisplayCopyDisplayMode(display),
              let native = nativeMode(for: display)
        else { return false }

        // Already native: nothing to do, and nothing to restore later.
        guard native.pixelWidth != current.pixelWidth
                || native.pixelHeight != current.pixelHeight else {
            if verbose { print("[velo] display already native, no switch") }
            return false
        }

        savedMode = current
        savedDisplay = display
        let result = CGDisplaySetDisplayMode(display, native, nil)
        if verbose {
            print("[velo] display \(current.pixelWidth)x\(current.pixelHeight)"
                  + " -> \(native.pixelWidth)x\(native.pixelHeight)"
                  + " @\(Int(native.refreshRate))Hz  status=\(result.rawValue)")
            fflush(stdout)
        }
        if result != .success {
            savedMode = nil
            savedDisplay = nil
            return false
        }
        return true
    }

    static func restore() {
        guard let display = savedDisplay, let mode = savedMode else { return }
        CGDisplaySetDisplayMode(display, mode, nil)
        savedMode = nil
        savedDisplay = nil
    }
}
