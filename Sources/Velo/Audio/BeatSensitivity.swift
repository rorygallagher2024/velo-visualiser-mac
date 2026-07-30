import Foundation

/// How readily a beat fires. Mirrors Android's `BeatSettings` — three presets
/// that scale the detector threshold and the audio-presence gate.
///
/// A higher `scale` makes the detector *harder* to trigger (fewer beats).
/// LOW amps the threshold by 1.8×, HIGH drops it to 0.6×.
enum BeatSensitivity: String, CaseIterable, Sendable {
    case low, standard, high

    var scale: Float {
        switch self {
        case .low:      return 1.8
        case .standard: return 1.0
        case .high:     return 0.6
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
