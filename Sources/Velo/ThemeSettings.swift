import Foundation

/// Five colour presets matching Android. Each is a hue rotation (radians about
/// the luma axis), a saturation scale, and an RGB tint — applied as a per-pixel
/// grade in every scene's fragment shader.
enum ThemePreset: String, CaseIterable {
    case `default` = "default"
    case neon = "neon"
    case warm = "warm"
    case cool = "cool"
    case mono = "mono"

    var label: String { rawValue.capitalized }

    var grade: ThemeGrade {
        switch self {
        case .default: ThemeGrade()
        case .neon:    ThemeGrade(saturation: 1.6)
        case .warm:    ThemeGrade(hueShift: 0.6, saturation: 1.05,
                                  tintR: 1.0, tintG: 0.82, tintB: 0.6)
        case .cool:    ThemeGrade(hueShift: -0.9, saturation: 1.05,
                                  tintR: 0.75, tintG: 0.9, tintB: 1.15)
        case .mono:    ThemeGrade(saturation: 0.0,
                                  tintR: 0.55, tintG: 1.0, tintB: 0.7)
        }
    }

    nonisolated(unsafe) static var current: ThemePreset = .default
}

struct ThemeGrade {
    var hueShift: Float = 0
    var saturation: Float = 1
    var tintR: Float = 1
    var tintG: Float = 1
    var tintB: Float = 1
}
