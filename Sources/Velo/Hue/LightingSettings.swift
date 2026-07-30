import Foundation

/// Shared, user-tunable light-rendering parameters. Every lighting integration's
/// sender thread reads this object plus the global BeatBus, so all brands react
/// to the music identically.
///
/// Reactivity is shaped by a ``Preset`` — the quick choice in the Lighting
/// section — which bundles the glow/brightness/flash knobs. The Advanced sliders
/// fine-tune those same knobs, flipping the preset to `.custom`.
///
/// Read on sender threads, set from the main thread.
final class LightingSettings: @unchecked Sendable {

    static let shared = LightingSettings()

    enum Preset: String, CaseIterable, Sendable {
        case smooth, reactive, strobe, custom
    }

    // MARK: - Defaults

    static let defaultColourSplit: Float = 0.5
    static let defaultPreset: Preset = .reactive

    // MARK: - Colour / timing (orthogonal to reactivity dynamics)

    var colourSplit: Float = defaultColourSplit

    // MARK: - Reactivity dynamics (set by preset; exposed as Advanced sliders)

    var restingGlow: Float = 0.22
    var audioBrightness: Float = 0.32
    var audioFlash: Float = 0.85

    /// Minimum seconds between beat flashes — prevents rapid-fire double hits
    /// from looking like a strobe in gentler presets.
    var beatCooldownSec: Float = 0.12

    /// Per-tick blend toward the target brightness. 1.0 = raw passthrough,
    /// lower = heavier lowpass. Applied in each sender's 50 Hz loop.
    var brightnessSmoothing: Float = 0.4

    var preset: Preset = defaultPreset

    func applyPreset(_ p: Preset) {
        switch p {
        case .smooth:   set(glow: 0.50, bright: 0.75, flash: 0.40, cooldown: 0.25, smoothing: 0.12)
        case .reactive: set(glow: 0.22, bright: 0.32, flash: 0.85, cooldown: 0.12, smoothing: 0.4)
        case .strobe:   set(glow: 0.0,  bright: 0.0,  flash: 1.0,  cooldown: 0,    smoothing: 1.0)
        case .custom:   break
        }
        preset = p
    }

    private func set(glow: Float, bright: Float, flash: Float,
                     cooldown: Float, smoothing: Float) {
        restingGlow = glow
        audioBrightness = bright
        audioFlash = flash
        beatCooldownSec = cooldown
        brightnessSmoothing = smoothing
    }

    func markCustom() { preset = .custom }

    func resetToDefaults() {
        colourSplit = Self.defaultColourSplit
        applyPreset(Self.defaultPreset)
    }

    // MARK: - Derived colour values

    private var splitMid: Float { 0.75 + (0.40 - 0.75) * colourSplit }
    var bassLo: Float { splitMid - 0.12 }
    var bassHi: Float { splitMid + 0.12 }

    // MARK: - Derived dynamics

    private var energyGain: Float { audioBrightness * 1.5 }
    private var beatPunch: Float { audioFlash * 1.8 }

    static let minBeatAmp: Float = 0.06
    private let audioRestScale: Float = 0.12

    private var audioFloor: Float { restingGlow * audioRestScale }

    func beatFlashAmp(_ loudness: Float) -> Float {
        Self.minBeatAmp + (1 - Self.minBeatAmp) * loudness
    }

    /// Audio mode brightness: base tracks steady energy, beat punches on top,
    /// resting on audioFloor. Shared by every brand.
    func audioBrightnessValue(low: Float, mid: Float, high: Float, flash: Float) -> Float {
        let energy = max(low, max(mid, high)).clamped(to: 0...1)
        let drive = (energy * energyGain + flash * beatPunch).clamped(to: 0...1)
        let floor = audioFloor
        return floor + (1 - floor) * sqrtf(drive)
    }

    // MARK: - Persistence

    private let defaults = UserDefaults.standard
    private let kPreset = "lighting_preset"
    private let kColourSplit = "lighting_colour_split"
    private let kGlow = "lighting_glow"
    private let kBright = "lighting_brightness"
    private let kFlash = "lighting_flash"

    func save() {
        defaults.set(preset.rawValue, forKey: kPreset)
        defaults.set(colourSplit, forKey: kColourSplit)
        defaults.set(restingGlow, forKey: kGlow)
        defaults.set(audioBrightness, forKey: kBright)
        defaults.set(audioFlash, forKey: kFlash)
    }

    func restore() {
        colourSplit = defaults.object(forKey: kColourSplit) as? Float ?? Self.defaultColourSplit
        if let raw = defaults.string(forKey: kPreset),
           let p = Preset(rawValue: raw) {
            if p == .custom {
                restingGlow = defaults.object(forKey: kGlow) as? Float ?? 0.22
                audioBrightness = defaults.object(forKey: kBright) as? Float ?? 0.32
                audioFlash = defaults.object(forKey: kFlash) as? Float ?? 0.85
                markCustom()
            } else {
                applyPreset(p)
            }
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
