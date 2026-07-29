import AppKit
import SwiftUI

/// The type scale, shared with the Android app.
///
/// Two families, doing different jobs. **Satoshi** is the working typeface:
/// labels, captions, values, anything being read rather than looked at. It is a
/// neutral grotesque that stays legible at ten points and does not ask for
/// attention.
///
/// **Clash Display** is the spectacle typeface, and it earns its place only at
/// size. Its character is in the wide apertures and the tight, confident joins,
/// none of which survive below about twenty points, so using it for a caption
/// gets all of its awkwardness and none of its presence. It is reserved for the
/// few moments that are meant to be looked at: the frame rate, the wordmark.
///
/// The weights are deliberately light. On black, at size, a regular weight
/// reads as heavy and a light weight reads as precise, which is the whole
/// monochrome white-on-black direction the brand sits in.
enum Velo {

    /// Registers the bundled faces. Idempotent, and safe to call before any
    /// view is built.
    ///
    /// The fonts ship inside the app rather than being expected on the system.
    /// `ATSApplicationFontsPath` in the plist covers a normally launched app,
    /// but a binary run straight from the build directory has no bundle
    /// resources to find, so they are registered by hand too and the app looks
    /// the same either way.
    static func registerFonts() {
        guard !registered else { return }
        registered = true
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
            URL(fileURLWithPath: "Resources/Fonts"),
        ].compactMap { $0 }

        for directory in candidates {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil) else { continue }
            let faces = files.filter { $0.pathExtension.lowercased() == "otf" }
            guard !faces.isEmpty else { continue }
            CTFontManagerRegisterFontURLs(faces as CFArray, .process, true, nil)
            return
        }
    }

    private nonisolated(unsafe) static var registered = false

    // MARK: - Spectacle

    /// The one number worth looking at. Extralight, because at this size the
    /// counters carry the shape and weight would only close them up.
    static func spectacle(_ size: CGFloat) -> Font {
        custom("ClashDisplay-Extralight", size: size, fallback: .thin)
    }

    /// Section headings and the wordmark.
    static func display(_ size: CGFloat) -> Font {
        custom("ClashDisplay-Light", size: size, fallback: .light)
    }

    // MARK: - Working type

    /// Body and control labels.
    static func body(_ size: CGFloat) -> Font {
        custom("Satoshi-Regular", size: size, fallback: .regular)
    }

    /// Small caps labels, captions, the quiet half of a row.
    static func label(_ size: CGFloat) -> Font {
        custom("Satoshi-Medium", size: size, fallback: .medium)
    }

    static func light(_ size: CGFloat) -> Font {
        custom("Satoshi-Light", size: size, fallback: .light)
    }

    /// Numbers that change every frame. Monospaced deliberately: a proportional
    /// digit set makes a live readout twitch sideways on every update, which is
    /// far more distracting than the numbers themselves.
    static func readout(_ size: CGFloat) -> Font {
        .system(size: size, weight: .regular, design: .monospaced)
    }

    private static func custom(
        _ name: String, size: CGFloat, fallback: Font.Weight
    ) -> Font {
        registerFonts()
        // Fall back to the system face rather than to a wrong one. NSFont
        // returns nil for a name it does not have, and SwiftUI's Font.custom
        // would silently substitute something arbitrary.
        return NSFont(name: name, size: size) == nil
            ? .system(size: size, weight: fallback)
            : .custom(name, size: size)
    }
}
