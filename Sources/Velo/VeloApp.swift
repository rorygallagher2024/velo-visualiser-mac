import SwiftUI
import UniformTypeIdentifiers

@main
struct VeloApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Velo Visualiser", id: "canvas") {
            ContentView(model: model)
                .background(.black)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1280, height: 720)
        // No `.keyboardShortcut` commands here for plain keys (M/H/F etc.) — a
        // menu key equivalent is matched before the responder chain, so plain
        // letters declared here would shadow the canvas view. Cmd+key combos
        // are fine because they don't collide.
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open Audio File\u{2026}") {
                    model.openAudioFilePanel()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}

/// App-wide state. `@Observable` rather than `ObservableObject`: SwiftUI only
/// re-renders the views that actually read a changed property, which matters
/// when a 120 Hz canvas shares a window with the controls.
@Observable
final class AppModel {
    var menuOpen = false
    var lightingOpen = false
    var visualPickerOpen = false
    var showingAbout = false
    var showingPrivacy = false
    /// Diagnostics overlay. Off by default: the canvas is meant to be pure
    /// output, and anything drawn over it lands in whatever captures the window.
    var perfOverlay = ProcessInfo.processInfo.environment["VELO_PERF"] != nil
    /// Polled from the render thread's stats at 4 Hz.
    var perf = PerfSnapshot()
    var audioStatus = AudioStatus()
    /// Polled at 4 Hz alongside perf stats so the UI refreshes.
    var linkPeers: Int = 0
    var linkBpm: Float = 0
    /// Filled once the canvas exists. See `StatsBox` for why this is not state.
    let statsBox = StatsBox()

    /// Held for the life of the app, to tell macOS this process is not idle.
    ///
    /// App Nap and timer coalescing exist to save power on processes that look
    /// like they are doing nothing much, and an app that renders on its own
    /// thread and presents drawables can look exactly like that from outside.
    /// `.latencyCritical` opts out of coalescing, and the user-initiated option
    /// says the work is on behalf of someone watching it happen.
    private let activity = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiated, .latencyCritical],
        reason: "Live audio visualisation")
    var sceneIndex = 0
    /// `VELO_HDR=1` starts in extended range, so the path can be exercised
    /// without driving the UI. Saved to UserDefaults so the user's choice persists.
    var hdrEnabled: Bool {
        didSet { UserDefaults.standard.set(hdrEnabled, forKey: "velo_hdr") }
    }

    var hdrAvailable: Bool {
        guard let screen = NSScreen.main else { return false }
        return screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.01
    }

    /// Syphon output for OBS / other Syphon clients. Persisted.
    var syphonEnabled: Bool = false {
        didSet { UserDefaults.standard.set(syphonEnabled, forKey: "velo_syphon") }
    }

    /// 0 means uncapped (present every vsync).
    var frameCap: Double = {
        if let c = ProcessInfo.processInfo.environment["VELO_CAP"], let v = Double(c) {
            return v
        }
        return 0
    }()
    /// Core Audio UID of the chosen input, or nil for the system default.
    ///
    /// Persisted so a rig comes back up on the same interface it was last
    /// performing on. A UID that is missing at launch is kept rather than
    /// cleared — an interface that is merely switched off should still be the
    /// remembered choice when it is plugged back in — and `AudioEngine.open`
    /// falls back to the default device in the meantime.
    var selectedDeviceUID: String? {
        didSet {
            guard selectedDeviceUID != oldValue else { return }
            UserDefaults.standard.set(selectedDeviceUID, forKey: Self.deviceUIDKey)
            rememberDeviceName()
        }
    }

    /// Friendly name of the remembered input, stored alongside the UID for the
    /// one case that needs it: naming a device in the picker while it is
    /// disconnected. A UID on its own is unreadable.
    private(set) var selectedDeviceName: String?

    static let deviceUIDKey = "velo_input_device_uid"
    static let deviceNameKey = "velo_input_device_name"

    private func rememberDeviceName() {
        guard let uid = selectedDeviceUID else {
            selectedDeviceName = nil
            UserDefaults.standard.removeObject(forKey: Self.deviceNameKey)
            return
        }
        guard let name = AudioEngine.inputDevices().first(where: { $0.uid == uid })?.name
        else { return }   // Unknown device: keep the name we already had.
        selectedDeviceName = name
        UserDefaults.standard.set(name, forKey: Self.deviceNameKey)
    }

    /// 4/4 Music Mode: grid-locks the beat to a steady four-to-the-floor
    /// signature. Persisted, default off. The renderer falls back to the
    /// reactive detector whenever it isn't confident.
    var fourFourEnabled: Bool = false {
        didSet {
            FourFourSync.enabled = fourFourEnabled
            UserDefaults.standard.set(fourFourEnabled, forKey: "velo_four_four")
        }
    }

    /// Ableton Link wireless tempo/beat sync. Persisted, default off.
    /// Link takes precedence over 4/4 Music Mode when both are on.
    var linkEnabled: Bool = false {
        didSet {
            LinkSync.enabled = linkEnabled
            LinkSession.setEnabled(linkEnabled)
            UserDefaults.standard.set(linkEnabled, forKey: "velo_link")
        }
    }

    /// Anticipatory beat swell (Link only). Persisted, default on.
    var linkAnticipate: Bool = true {
        didSet {
            LinkSync.anticipateBeat = linkAnticipate
            UserDefaults.standard.set(linkAnticipate, forKey: "velo_link_anticipate")
        }
    }

    /// Manual downbeat alignment (0..3). Persisted, default 0.
    var linkBarOffset: Int = 0 {
        didSet {
            LinkSync.barOffsetBeats = linkBarOffset
            UserDefaults.standard.set(linkBarOffset, forKey: "velo_link_bar_offset")
        }
    }

    var beatSensitivity: BeatSensitivity = .standard {
        didSet {
            BeatBus.sensitivity = beatSensitivity
            UserDefaults.standard.set(beatSensitivity.rawValue, forKey: "velo_beat_sens")
        }
    }

    var showBeatsOnVisuals: Bool = true {
        didSet {
            BeatBus.showBeatsOnVisuals = showBeatsOnVisuals
            UserDefaults.standard.set(showBeatsOnVisuals, forKey: "velo_show_beats")
        }
    }

    var themePreset: ThemePreset = .default {
        didSet {
            ThemePreset.current = themePreset
            UserDefaults.standard.set(themePreset.rawValue, forKey: "velo_theme")
        }
    }

    var crystalSwarmGrid: Int = 32 {
        didSet {
            CrystalSwarmScene.gridSize = crystalSwarmGrid
            UserDefaults.standard.set(crystalSwarmGrid, forKey: "velo_swarm_grid")
        }
    }

    var dynamicWebColor: Bool = true {
        didSet {
            DynamicWebScene.colorEnabled = dynamicWebColor
            UserDefaults.standard.set(dynamicWebColor, forKey: "velo_dynamic_web_color")
        }
    }

    static let swarmDensityPresets = [32, 24, 18, 12, 8]

    var visualsDisabled: Bool = false {
        didSet { UserDefaults.standard.set(visualsDisabled, forKey: "velo_visuals_off") }
    }

    var transitionsEnabled: Bool = false {
        didSet { UserDefaults.standard.set(transitionsEnabled, forKey: "velo_transitions") }
    }

    var transitionDuration: Double = 10.0 {
        didSet { UserDefaults.standard.set(transitionDuration, forKey: "velo_transition_duration") }
    }

    var favourites: [Int] = [] {
        didSet { UserDefaults.standard.set(favourites, forKey: "velo_favourites") }
    }

    func toggleFavourite(_ index: Int) {
        if let pos = favourites.firstIndex(of: index) {
            favourites.remove(at: pos)
        } else {
            favourites.append(index)
        }
    }

    /// The scene a numbered slot recalls. With favourites saved, the slots are
    /// the favourites; with none saved they fall through to the catalogue in
    /// order. Shared by the number keys and the MIDI favourite mappings so both
    /// always land on the same visual.
    func sceneForSlot(_ slot: Int) -> Int? {
        if !favourites.isEmpty {
            return slot < favourites.count ? favourites[slot] : nil
        }
        return slot < SceneCatalog.names.count ? slot : nil
    }

    let audio = AudioEngine()
    let tone = ToneGenerator()
    let filePlayer = FilePlayer()
    let hue = HueState()
    let lifx = LifxState()
    let nanoleaf = NanoleafState()
    var midi = MidiController()

    /// Test-tone mode. Not persisted — always starts on mic.
    var toneActive: Bool = false {
        didSet {
            if toneActive {
                stopFilePlayback()
                tone.start(audioEngine: audio)
            } else {
                tone.stop()
            }
        }
    }

    var playbackURL: URL?
    var playbackActive: Bool = false
    var playbackPaused: Bool = false

    func startFilePlayback(url: URL) {
        if toneActive { toneActive = false }
        playbackURL = url
        filePlayer.play(url: url, audioEngine: audio)
        playbackActive = filePlayer.isPlaying
        playbackPaused = filePlayer.isPaused
    }

    func stopFilePlayback() {
        guard filePlayer.isPlaying else { return }
        filePlayer.stop()
        playbackURL = nil
        playbackActive = false
        playbackPaused = false
    }

    func toggleFilePlayPause() {
        filePlayer.togglePlayPause()
        playbackPaused = filePlayer.isPaused
    }

    func seekFile(to time: TimeInterval) {
        filePlayer.seek(to: time)
    }

    @MainActor func openAudioFilePanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .mp3, .wav, .aiff]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an audio file to visualise"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        startFilePlayback(url: url)
    }

    /// Tone frequency (Hz), log-mapped.
    var toneFreq: Float = 440 {
        didSet {
            tone.leftHz = toneFreq
            if !toneXY { tone.rightHz = toneFreq }
        }
    }

    /// Independent right-channel frequency for Lissajous X-Y mode.
    var toneFreqRight: Float = 440 {
        didSet { tone.rightHz = toneFreqRight }
    }

    /// Signal amplitude 0..1.
    var toneLevel: Float = 0.10 {
        didSet { tone.level = toneLevel }
    }

    /// X-Y mode: independent L/R frequencies for Lissajous figures.
    var toneXY: Bool = false {
        didSet {
            if toneXY {
                tone.rightHz = toneFreqRight
            } else {
                tone.rightHz = toneFreq
            }
        }
    }

    init() {
        let envHDR = ProcessInfo.processInfo.environment["VELO_HDR"] != nil
        self.hdrEnabled = envHDR || UserDefaults.standard.bool(forKey: "velo_hdr")
        self.syphonEnabled = UserDefaults.standard.bool(forKey: "velo_syphon")

        let ff = UserDefaults.standard.bool(forKey: "velo_four_four")
        self.fourFourEnabled = ff
        FourFourSync.enabled = ff

        let link = UserDefaults.standard.bool(forKey: "velo_link")
        self.linkEnabled = link
        LinkSync.enabled = link
        if link { LinkSession.setEnabled(true) }

        let antic = UserDefaults.standard.object(forKey: "velo_link_anticipate") as? Bool ?? true
        self.linkAnticipate = antic
        LinkSync.anticipateBeat = antic

        let offset = UserDefaults.standard.integer(forKey: "velo_link_bar_offset")
        self.linkBarOffset = min(max(offset, 0), 3)
        LinkSync.barOffsetBeats = self.linkBarOffset

        if let raw = UserDefaults.standard.string(forKey: "velo_beat_sens"),
           let s = BeatSensitivity(rawValue: raw) {
            self.beatSensitivity = s
            BeatBus.sensitivity = s
        }

        let beats = UserDefaults.standard.object(forKey: "velo_show_beats") as? Bool ?? true
        self.showBeatsOnVisuals = beats
        BeatBus.showBeatsOnVisuals = beats

        if let themeKey = UserDefaults.standard.string(forKey: "velo_theme"),
           let t = ThemePreset(rawValue: themeKey) {
            self.themePreset = t
            ThemePreset.current = t
        }

        self.visualsDisabled = UserDefaults.standard.bool(forKey: "velo_visuals_off")
        
        self.transitionsEnabled = UserDefaults.standard.bool(forKey: "velo_transitions")
        let savedDuration = UserDefaults.standard.double(forKey: "velo_transition_duration")
        if savedDuration > 0 {
            self.transitionDuration = savedDuration
        }

        let grid = UserDefaults.standard.integer(forKey: "velo_swarm_grid")
        if grid >= 6 && grid <= 32 {
            self.crystalSwarmGrid = grid
            CrystalSwarmScene.gridSize = grid
        }

        if UserDefaults.standard.object(forKey: "velo_dynamic_web_color") != nil {
            let webCol = UserDefaults.standard.bool(forKey: "velo_dynamic_web_color")
            self.dynamicWebColor = webCol
            DynamicWebScene.colorEnabled = webCol
        }

        let maxScene = SceneCatalog.names.count
        if let saved = UserDefaults.standard.array(forKey: "velo_favourites") as? [Int] {
            self.favourites = saved.filter { $0 >= 0 && $0 < maxScene }
        }

        // Assigned before start() so capture opens on the remembered input
        // rather than the default and then switching a moment later.
        // Assignment in init does not fire didSet, so this cannot write back
        // the value it just read.
        self.selectedDeviceUID = UserDefaults.standard.string(forKey: Self.deviceUIDKey)
        self.selectedDeviceName = UserDefaults.standard.string(forKey: Self.deviceNameKey)

        HueCredentialStore.migrateFromKeychain()
        if ProcessInfo.processInfo.environment["VELO_SELFTEST"] != nil { SelfTest.run() }
        VeloLog.begin()
        audio.start(deviceUID: selectedDeviceUID)

        filePlayer.onPlaybackStateChange = { [weak self] in
            guard let self else { return }
            self.playbackActive = self.filePlayer.isPlaying
            self.playbackPaused = self.filePlayer.isPaused
        }

        midi.onAction = { [weak self] action in
            guard let self else { return }
            let count = SceneCatalog.names.count
            switch action {
            case .previousVisual:
                sceneIndex = ((sceneIndex - 1) % count + count) % count
            case .nextVisual:
                sceneIndex = (sceneIndex + 1) % count
            case .favourite(let slot):
                if let target = sceneForSlot(slot) { sceneIndex = target }
            }
        }
    }
}
