import Foundation

/// The fixed list of visuals, in switch order.
///
/// Single source of truth: the renderer builds from `makeAll`, the controls
/// label from `names`, and the two cannot drift apart. Instruments first, then
/// the generative ones, matching the Android catalogue's grouping.
enum SceneCatalog {
    static let names = [
        // Instruments: honest readouts of the signal.
        "Spectrum Analyser",
        "Raw Oscilloscope",
        "Phosphor Scope",
        "Circular Spectrum",
        "Pocket LED",
        "Spectrum Bars",
        "3D LED",
        "Spectrogram",
        "Waveform",
        "Waveform 3D",
        "Waveform 3D Void",
        // Generative: driven by band energy rather than measuring it.
        "Tunnel",
        "Laser Array",
        "Spectral Bloom",
        "Aurora Drift",
        "Quicksilver",
        "Nebula",
    ]

    static func makeAll() -> [VeloScene] {
        [
            SpectrumAnalyserScene(),
            RawOscilloscopeScene(),
            PhosphorScopeScene(),
            CircularSpectrumScene(),
            PocketLedScene(),
            BarSpectrumScene(),
            LedMatrix3DScene(),
            SpectrogramScene(),
            WaveformScene(),
            Waveform3DScene(style: .room),
            Waveform3DScene(style: .void),
            TunnelScene(),
            LaserArrayScene(),
            SpectralBloomScene(),
            AuroraDriftScene(),
            QuicksilverScene(),
            NebulaScene(),
        ]
    }

    /// The shared per-frame scene buffer, sized once for the largest payload so
    /// switching visuals never reallocates mid-flight. The biggest today is a
    /// scope's PCM window plus a few scalars; the headroom is deliberate, since
    /// the alternative is tying the buffer to one scene's constant and having
    /// the next scene quietly run four bytes past the end of it.
    static let sceneBufferBytes = 8192
}
