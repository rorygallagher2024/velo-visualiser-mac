import Foundation

/// The fixed list of visuals, in switch order.
///
/// Single source of truth: the renderer builds from `makeAll`, the controls
/// label from `names`, and the two cannot drift apart. Instruments first, then
/// the generative ones, matching the Android catalogue's grouping.
enum SceneCatalog {
    static let names = [
        // Instruments — honest readouts of the signal.
        "Spectrum Analyser",
        "Raw Oscilloscope",
        "Circular Spectrum",
        "Pocket LED",
        // Generative — driven by band energy rather than measuring it.
        "Tunnel",
        "Laser Array",
        "Spectral Bloom",
        "Aurora Drift",
    ]

    static func makeAll() -> [VeloScene] {
        [
            SpectrumAnalyserScene(),
            RawOscilloscopeScene(),
            CircularSpectrumScene(),
            PocketLedScene(),
            TunnelScene(),
            LaserArrayScene(),
            SpectralBloomScene(),
            AuroraDriftScene(),
        ]
    }
}
