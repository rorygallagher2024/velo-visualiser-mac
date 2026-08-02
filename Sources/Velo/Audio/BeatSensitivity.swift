import Foundation

/// How readily a beat fires. Mirrors Android's `BeatSettings` — three presets
/// that scale the detector threshold and the audio-presence gate.
///
/// A higher scale makes the detector *harder* to trigger (fewer beats).
/// Source-aware: file/internal audio arrives much hotter than the mic, so the
/// same preset applies a higher threshold there (matching Android's
/// `micScale` / `internalScale` split).
enum BeatSensitivity: String, CaseIterable, Sendable {
    case low, standard, high

    var micScale: Float {
        switch self {
        case .low:      return 1.8
        case .standard: return 1.0
        case .high:     return 0.6
        }
    }

    var fileScale: Float {
        switch self {
        case .low:      return 4.0
        case .standard: return 2.2
        case .high:     return 1.4
        }
    }

    var label: String {
        switch self {
        case .low:      return "Low"
        case .standard: return "Standard"
        case .high:     return "High"
        }
    }
}
