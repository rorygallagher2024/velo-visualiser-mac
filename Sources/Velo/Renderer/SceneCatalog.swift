import Foundation

/// The fixed list of visuals, in switch order.
///
/// Single source of truth: the renderer builds from `makeAll`, the controls
/// label from `names`, and the two cannot drift apart. Instruments first, then
/// the generative ones, matching the Android catalogue's grouping.
enum SceneCatalog {
    static let generativeStart = 16

    /// Visuals that read well composited over a camera feed.
    ///
    /// Keyed by NAME rather than by index, and the catalogue order is left
    /// alone. `AppModel.favourites` persists scene *indices*, and the MIDI slot
    /// mappings resolve through it, so reordering this list would silently point
    /// somebody's saved favourites and pads at different visuals.
    ///
    /// What earns a place: mostly black, so a Screen or Add blend in OBS leaves
    /// the footage visible; sparse or edge-weighted, so it does not sit on the
    /// subject's face; and calm enough to decorate rather than compete. That
    /// last one is why the busiest generative scenes are not here even though
    /// they composite cleanly.
    static let overlayNames: Set<String> = [
        "Lattice",
        "Starscape",
        "Deep Field",
        "Prism Field",
        "Colour Wash",
        "Colour Bath",
        "Light Leak",
        "Laser Array",
        "Corner Bloom",
        "Beat Fireworks",
        "Chromatic Dots",
        "Chromatic Frame",
        "Edge Equaliser",
        "Edge Waveform",
    ]

    /// Indices of the overlay visuals, in catalogue order.
    static let overlayIndices: [Int] =
        names.indices.filter { overlayNames.contains(names[$0]) }

    /// The other two groups, with the overlays lifted out so nothing is listed
    /// twice.
    static let instrumentIndices: [Int] =
        (0..<generativeStart).filter { !overlayNames.contains(names[$0]) }

    static let generativeIndices: [Int] =
        (generativeStart..<names.count).filter { !overlayNames.contains(names[$0]) }

    static let names = [
        // Instruments: honest readouts of the signal.
        "Level Meter",
        "Mechanical Meter",
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
        "Phase Scope",
        "CRT Scope",
        "Lissajous Scope",
        // Generative: driven by band energy rather than measuring it.
        "Beat Pulse",
        "Starscape",
        "Tunnel",
        "Lattice",
        "Laser Array",
        "Spectral Bloom",
        "Aurora Drift",
        "Quicksilver",
        "Electric Iris",
        "Nebula",
        "Deep Field",
        "Prism Field",
        "Colour Wash",
        "Colour Bath",
        "Light Leak",
        "Phyllotaxis Bloom",
        "Corner Bloom",
        "Beat Fireworks",
        "Chromatic Dots",
        "Chromatic Frame",
        "Edge Equaliser",
        "Edge Waveform",
        "Crystal Swarm",
        "Particle Dust",
        "Ethereal Ribbons",
        "Abstract Waveform",
        "Spectral Canyon",
        "Flux",
        "Fractal Cathedral",
        "Corner Shatter",
        "Strange Attractor",
        "Topographic Ridge",
        "Plasma Storm",
        "Audio Web",
        "Dynamic Web",
    ]

    static func makeAll() -> [VeloScene] {
        [
            LevelMeterScene(),
            MechanicalMeterScene(),
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
            PhaseScopeScene(),
            CrtScopeScene(),
            LissajousScopeScene(),
            BeatPulseScene(),
            StarscapeScene(),
            TunnelScene(),
            LatticeScene(),
            LaserArrayScene(),
            SpectralBloomScene(),
            AuroraDriftScene(),
            QuicksilverScene(),
            ElectricIrisScene(),
            NebulaScene(),
            DeepFieldScene(),
            PrismFieldScene(),
            ColourWashScene(),
            ColourBathScene(),
            LightLeakScene(),
            PhyllotaxisScene(),
            PhyllotaxisCornersScene(),
            BeatFireworksScene(),
            ChromaticDotsScene(),
            ChromaticFrameScene(),
            EdgeEqualiserScene(),
            EdgeWaveformScene(),
            CrystalSwarmScene(),
            ParticleDustScene(),
            EtherealRibbonsScene(),
            AbstractWaveformScene(),
            SpectralCanyonScene(),
            FluxScene(),
            MandelboxScene(),
            CornerShatterScene(),
            StrangeAttractorScene(),
            TopographicRidgeScene(),
            PlasmaStormScene(),
            AudioWebScene(),
            DynamicWebScene(),
        ]
    }

    /// The shared per-frame scene buffer, sized once for the largest payload so
    /// switching visuals never reallocates mid-flight. The biggest today is a
    /// scope's PCM window plus a few scalars; the headroom is deliberate, since
    /// the alternative is tying the buffer to one scene's constant and having
    /// the next scene quietly run four bytes past the end of it.
    static let sceneBufferBytes = 8192
}
