import SwiftUI

/// The window. The canvas is the whole surface — no persistent chrome, matching
/// the Android app's "pure output" rule. Controls slide in only when asked for,
/// and every one of them has a key.
struct ContentView: View {
    @Bindable var model: AppModel

    /// Polled rather than pushed. The stats are written from the render thread
    /// every frame, and driving SwiftUI at that rate would spend more time
    /// laying out text than rendering. Four times a second is live enough to
    /// watch and cheap enough to ignore.
    private let tick = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            MetalCanvasView(
                hdrEnabled: model.hdrEnabled,
                syphonEnabled: model.syphonEnabled,
                audio: model.audio,
                onToggleMenu: {
                    model.menuOpen.toggle()
                    if model.menuOpen { model.lightingOpen = false }
                },
                onToggleLighting: {
                    model.lightingOpen.toggle()
                    if model.lightingOpen { model.menuOpen = false }
                },
                onToggleHDR: { model.hdrEnabled.toggle() },
                onTogglePerf: { model.perfOverlay.toggle() },
                onToggleSyphon: { model.syphonEnabled.toggle() },
                onToggleBeats: { model.showBeatsOnVisuals.toggle() },
                onCycleTheme: {
                    let all = ThemePreset.allCases
                    let i = all.firstIndex(of: model.themePreset) ?? all.startIndex
                    model.themePreset = all[(all.distance(from: all.startIndex, to: i) + 1) % all.count]
                },
                onStats: { model.statsBox.stats = $0 },
                frameCap: model.frameCap,
                sceneIndex: model.sceneIndex,
                onSceneChange: { model.sceneIndex = $0 }
            )
            .ignoresSafeArea()

            if model.syphonEnabled {
                SyphonModePanel(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black)
            } else {
                if model.perfOverlay {
                    PerfOverlay(
                        snapshot: model.perf,
                        scene: SceneCatalog.names[model.sceneIndex],
                        audio: model.audioStatus,
                        hdr: model.hdrEnabled,
                        syphon: model.syphonEnabled,
                        toneActive: model.toneActive
                    )
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .transition(.opacity)
                    .allowsHitTesting(false)
                }

                if model.menuOpen {
                    ControlPanel(model: model)
                        .padding(20)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else if model.lightingOpen {
                    LightingPanel(model: model)
                        .padding(20)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else {
                    HintBar()
                        .padding(14)
                }
            }
        }
        .background(.black)
        .animation(.easeOut(duration: 0.18), value: model.menuOpen)
        .animation(.easeOut(duration: 0.18), value: model.lightingOpen)
        .animation(.easeOut(duration: 0.18), value: model.perfOverlay)
        .animation(.easeOut(duration: 0.18), value: model.syphonEnabled)
        .onReceive(tick) { _ in
            if model.linkEnabled {
                model.linkPeers = LinkSync.statusPeers
                model.linkBpm = LinkSync.statusBpm
            }
            if let stats = model.statsBox.stats { model.perf = stats.snapshot }
            model.audioStatus = model.audio.status()
        }
    }
}

/// A quiet, transient reminder of the keys. There is no on-screen button to
/// open the menu on purpose: a visible control would show up in the OBS capture.
private struct HintBar: View {
    @State private var visible = true

    var body: some View {
        Text("M controls · L lighting · T theme · S syphon · B beats · F fullscreen · H HDR · P stats · ← → visual")
            .font(Velo.light(13))
            .tracking(0.4)
            .foregroundStyle(.white.opacity(0.35))
            .opacity(visible ? 1 : 0)
            .task {
                try? await Task.sleep(for: .seconds(4))
                withAnimation(.easeOut(duration: 1.2)) { visible = false }
            }
    }
}

/// The Velo mark. Falls back to type if the image is missing, so a bundle
/// without it degrades to something deliberate rather than to a blank gap.
private struct Wordmark: View {
    var body: some View {
        if let url = Bundle.main.url(forResource: "velo_v", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(height: 30)
                .opacity(0.92)
        } else {
            Text("VELO")
                .font(Velo.display(22))
                .tracking(5)
                .foregroundStyle(.white.opacity(0.9))
        }
    }
}

/// Settings, modelled on the Android sheet: dark panel, small caps section
/// headers, captions beneath their control.
///
/// The HDR caption reports live display headroom, because a toggle that does
/// nothing is indistinguishable from a toggle that is broken.
private struct ControlPanel: View {
    @Bindable var model: AppModel
    @State private var devices: [AudioInputDevice] = []

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                Wordmark().padding(.bottom, 18)

                section("Visual")
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Visual", selection: $model.sceneIndex) {
                        ForEach(Array(SceneCatalog.names.enumerated()), id: \.offset) { i, n in
                            Text(n).tag(i)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 280)
                    caption("Number keys pick a visual directly; left and right "
                            + "arrows step through them.")
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Theme")
                        .font(Velo.label(13))
                        .foregroundStyle(.white.opacity(0.5))
                    HStack(spacing: 4) {
                        ForEach(ThemePreset.allCases, id: \.self) { t in
                            Button(t.label) { model.themePreset = t }
                                .buttonStyle(.bordered)
                                .controlSize(.regular)
                                .opacity(model.themePreset == t ? 1.0 : 0.4)
                        }
                    }
                    caption("Colour grade applied to every visual. "
                            + "T cycles through them.")
                }

                Divider().overlay(.white.opacity(0.12))

                section("Audio")
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Input", selection: $model.selectedDeviceUID) {
                        Text("System default").tag(String?.none)
                        ForEach(devices) { device in
                            Text(device.name).tag(String?.some(device.uid))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 280)
                    .disabled(model.toneActive)
                    .opacity(model.toneActive ? 0.4 : 1)
                    caption(model.toneActive
                            ? "Disabled while the test tone is active."
                            : "Any Core Audio input. Use your interface to take a "
                            + "mixer feed directly, or a loopback device to "
                            + "visualise what the Mac itself is playing.")
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Beat Sensitivity")
                        .font(Velo.label(13))
                        .foregroundStyle(.white.opacity(0.5))
                    HStack(spacing: 4) {
                        ForEach(BeatSensitivity.allCases, id: \.self) { s in
                            Button(s.label) { model.beatSensitivity = s }
                                .buttonStyle(.bordered)
                                .controlSize(.regular)
                                .opacity(model.beatSensitivity == s ? 1.0 : 0.4)
                        }
                    }
                    caption("How readily the beat detector fires. Low is "
                            + "calmer, High triggers on quieter hits.")
                }

                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Show beats on visuals", isOn: $model.showBeatsOnVisuals)
                        .toggleStyle(.switch)
                    caption("When off, visuals respond to the music's energy but "
                            + "don't flash on individual beats. Useful with chroma "
                            + "key in OBS, where white flashes go transparent. "
                            + "Lights and haptics still react to beats.")
                }

                VStack(alignment: .leading, spacing: 6) {
                    Toggle("4/4 Music Mode", isOn: $model.fourFourEnabled)
                        .toggleStyle(.switch)
                    if model.fourFourEnabled {
                        caption("Experimental. Locks onto a steady four-to-the-floor beat "
                                + "and ignores stray hits between the beats, so the visuals "
                                + "and lights pulse cleanly on the grid. Reads the beat from "
                                + "the audio itself — no Ableton Link or DJ software needed. "
                                + "Best for house, techno and other steady 4/4 electronic "
                                + "music. Leave it off for live music, breakbeat or anything "
                                + "with a loose or changing rhythm.")
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Test tone", isOn: $model.toneActive)
                        .toggleStyle(.switch)
                    caption("Replaces the mic with a synthetic sine wave. Audible "
                            + "through the speakers and mirrored into the visuals, "
                            + "so every scene reacts exactly as it would to a real "
                            + "input.")
                }

                if model.toneActive {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text("Freq")
                                .font(Velo.label(12))
                                .foregroundStyle(.white.opacity(0.5))
                                .frame(width: 36, alignment: .leading)
                            Slider(value: toneFreqBinding,
                                   in: 0...1)
                                .frame(maxWidth: .infinity)
                            Text(String(format: "%d Hz", Int(model.toneFreq)))
                                .font(Velo.readout(12))
                                .monospacedDigit()
                                .frame(width: 60, alignment: .trailing)
                        }
                        if model.toneXY {
                            HStack(spacing: 8) {
                                Text("R")
                                    .font(Velo.label(12))
                                    .foregroundStyle(.white.opacity(0.5))
                                    .frame(width: 36, alignment: .leading)
                                Slider(value: toneFreqRightBinding,
                                       in: 0...1)
                                    .frame(maxWidth: .infinity)
                                Text(String(format: "%d Hz", Int(model.toneFreqRight)))
                                    .font(Velo.readout(12))
                                    .monospacedDigit()
                                    .frame(width: 60, alignment: .trailing)
                            }
                        }
                        HStack(spacing: 8) {
                            Text("Level")
                                .font(Velo.label(12))
                                .foregroundStyle(.white.opacity(0.5))
                                .frame(width: 36, alignment: .leading)
                            Slider(value: $model.toneLevel,
                                   in: 0...1)
                                .frame(maxWidth: .infinity)
                            Text(String(format: "%d%%", Int(model.toneLevel * 100)))
                                .font(Velo.readout(12))
                                .monospacedDigit()
                                .frame(width: 60, alignment: .trailing)
                        }
                        Toggle("X-Y mode", isOn: $model.toneXY)
                            .toggleStyle(.switch)
                        caption("Independent L/R frequencies for Lissajous figures "
                                + "on the scope scenes.")
                    }
                }

                Divider().overlay(.white.opacity(0.12))

                section("Ableton Link")
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Link sync", isOn: $model.linkEnabled)
                        .toggleStyle(.switch)
                    caption("Wireless tempo and beat sync with Ableton Live, Traktor, "
                            + "rekordbox and any Link-enabled app on the same network. "
                            + "The mic still drives the visuals; Link controls when the "
                            + "beat lands.")
                    if model.linkEnabled {
                        linkStatus
                    }
                }

                if model.linkEnabled {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Beat anticipation", isOn: $model.linkAnticipate)
                            .toggleStyle(.switch)
                        caption("Swells into each beat before snapping on the hit. "
                                + "Only possible with Link, since the shared clock "
                                + "knows where the next beat lands.")
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Stepper("Downbeat nudge: \(model.linkBarOffset)",
                                value: $model.linkBarOffset, in: 0...3)
                        caption("Link shares the beat grid but not where the musical "
                                + "\"1\" sits. Nudge 0\u{2013}3 beats to align the bar "
                                + "with the music.")
                    }
                }

                Divider().overlay(.white.opacity(0.12))

                section("Display")
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("HDR", isOn: $model.hdrEnabled)
                        .toggleStyle(.switch)
                    caption("Brighter highlights, on displays that can show them.")
                    if let warning = Self.headroomWarning(hdrOn: model.hdrEnabled) {
                        caption(warning)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Picker("Frame rate", selection: $model.frameCap) {
                        Text("60 fps").tag(60.0)
                        Text("120 fps").tag(120.0)
                        Text("240 fps").tag(240.0)
                        Text("Unlimited").tag(0.0)
                    }
                    .labelsHidden()
                    .frame(width: 280)
                    caption("Applies in windowed and fullscreen alike. A 60 fps "
                            + "stream gains nothing from rendering faster, and the "
                            + "headroom keeps the machine cool and quiet.")
                }

                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Diagnostics overlay", isOn: $model.perfOverlay)
                        .toggleStyle(.switch)
                    caption("Frame timing, the live visual and the audio input. Also on the "
                            + "P key. It draws over the canvas, so it will appear in a capture.")
                }

                Divider().overlay(.white.opacity(0.12))

                section("Streaming")
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Syphon output", isOn: $model.syphonEnabled)
                        .toggleStyle(.switch)
                    caption("Shares the canvas as a Syphon source. In OBS, add a "
                            + "\"Syphon Client\" source and select \"Velo Visualiser\". "
                            + "Zero-copy GPU sharing — no window capture needed.")
                }

                Divider().overlay(.white.opacity(0.12))

                section("About")
                VStack(alignment: .leading, spacing: 6) {
                    Button("About & Licenses") {
                        model.showingAbout = true
                    }
                    .buttonStyle(.link)
                    .font(Velo.light(16))
                    .foregroundStyle(.blue)

                    Button("Privacy Policy") {
                        model.showingPrivacy = true
                    }
                    .buttonStyle(.link)
                    .font(Velo.light(16))
                    .foregroundStyle(.blue)
                }

                Text("M close · L lighting · F fullscreen · H HDR · ← → visual")
                    .font(Velo.label(12))
                    .foregroundStyle(.white.opacity(0.3))
            }
            .padding(20)
        }
        .frame(width: 340)
        .background(.black.opacity(0.82), in: .rect(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.10), lineWidth: 1)
        )
        .foregroundStyle(.white)
        .task {
            devices = AudioEngine.inputDevices()
        }
        .onChange(of: model.selectedDeviceUID) { _, uid in
            model.audio.start(deviceUID: uid)
        }
        .sheet(isPresented: $model.showingAbout) {
            AboutView()
        }
        .sheet(isPresented: $model.showingPrivacy) {
            PrivacyView()
        }
    }

    private var toneFreqBinding: Binding<Float> {
        Binding(
            get: { log(model.toneFreq / 20) / log(1000) },
            set: { model.toneFreq = 20 * powf(1000, $0) }
        )
    }

    private var toneFreqRightBinding: Binding<Float> {
        Binding(
            get: { log(model.toneFreqRight / 20) / log(1000) },
            set: { model.toneFreqRight = 20 * powf(1000, $0) }
        )
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased())
            .font(Velo.display(14))
            .tracking(1.6)
            .tracking(1.1)
            .foregroundStyle(.white.opacity(0.45))
    }

    /// Said only when something is wrong.
    ///
    /// A number nobody asked for is noise, but silently doing nothing is worse:
    /// macOS grants no headroom until something requests extended range, so a
    /// display can be perfectly capable and still show no effect until the
    /// brightness comes down.
    static func headroomWarning(hdrOn: Bool) -> String? {
        guard let screen = NSScreen.main else { return nil }
        guard screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.01 else {
            return "This display cannot show extended range."
        }
        guard hdrOn,
              screen.maximumExtendedDynamicRangeColorComponentValue <= 1.01
        else { return nil }
        return "No headroom at this brightness. Turn the display down to see it."
    }

    private var linkStatus: some View {
        let peers = model.linkPeers
        let bpm = model.linkBpm
        let text: String
        if peers <= 0 {
            text = "Searching for peers\u{2026}"
        } else {
            text = String(format: "%d peer%@ \u{00B7} %.0f bpm", peers, peers == 1 ? "" : "s", bpm)
        }
        return Text(text)
            .font(Velo.readout(13))
            .foregroundStyle(.white.opacity(0.65))
            .monospacedDigit()
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(Velo.light(13))
            .foregroundStyle(.white.opacity(0.5))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Replaces the canvas when Syphon output is active. The renderer keeps
/// running headless (feeding the Syphon 4K output) while the window shows
/// this compact control surface.
private struct SyphonModePanel: View {
    @Bindable var model: AppModel
    @State private var devices: [AudioInputDevice] = []

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    Wordmark().padding(.bottom, 4)

                    syphonStatus

                    Divider().overlay(.white.opacity(0.12))

                    section("Visual")
                    Picker("Visual", selection: $model.sceneIndex) {
                        ForEach(Array(SceneCatalog.names.enumerated()), id: \.offset) { i, n in
                            Text(n).tag(i)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 280)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Theme")
                            .font(Velo.label(13))
                            .foregroundStyle(.white.opacity(0.5))
                        HStack(spacing: 4) {
                            ForEach(ThemePreset.allCases, id: \.self) { t in
                                Button(t.label) { model.themePreset = t }
                                    .buttonStyle(.bordered)
                                    .controlSize(.regular)
                                    .opacity(model.themePreset == t ? 1.0 : 0.4)
                            }
                        }
                    }

                    Divider().overlay(.white.opacity(0.12))

                    section("Audio")
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("Input", selection: $model.selectedDeviceUID) {
                            Text("System default").tag(String?.none)
                            ForEach(devices) { device in
                                Text(device.name).tag(String?.some(device.uid))
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 280)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Beat Sensitivity")
                            .font(Velo.label(13))
                            .foregroundStyle(.white.opacity(0.5))
                        HStack(spacing: 4) {
                            ForEach(BeatSensitivity.allCases, id: \.self) { s in
                                Button(s.label) { model.beatSensitivity = s }
                                    .buttonStyle(.bordered)
                                    .controlSize(.regular)
                                    .opacity(model.beatSensitivity == s ? 1.0 : 0.4)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Show beats on visuals", isOn: $model.showBeatsOnVisuals)
                            .toggleStyle(.switch)
                        caption("Off for chroma key: prevents white flashes "
                                + "going transparent. Lights still react.")
                    }

                    Divider().overlay(.white.opacity(0.12))

                    section("Output")
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Syphon output", isOn: $model.syphonEnabled)
                            .toggleStyle(.switch)
                        caption("Turn off to return to the live canvas.")
                    }

                    Divider().overlay(.white.opacity(0.12))

                    Text("← → change visual · S syphon · L lighting · F fullscreen")
                        .font(Velo.label(12))
                        .foregroundStyle(.white.opacity(0.3))
                }
                .padding(24)
            }
        }
        .frame(maxWidth: 380)
        .foregroundStyle(.white)
        .task { devices = AudioEngine.inputDevices() }
        .onChange(of: model.selectedDeviceUID) { _, uid in
            model.audio.start(deviceUID: uid)
        }
    }

    private var syphonStatus: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
                Text("SYPHON ACTIVE")
                    .font(Velo.display(13))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.7))
            }
            Text("3840 \u{00D7} 2160 \u{00B7} \(Int(model.perf.fps)) fps")
                .font(Velo.readout(14))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased())
            .font(Velo.display(14))
            .tracking(1.6)
            .foregroundStyle(.white.opacity(0.45))
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(Velo.light(13))
            .foregroundStyle(.white.opacity(0.5))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Dedicated lighting panel, opened with the L key.
private struct LightingPanel: View {
    @Bindable var model: AppModel
    @State private var brand: LightBrand = .hue

    enum LightBrand: String, CaseIterable {
        case hue = "Hue"
        case lifx = "LIFX"
        case nanoleaf = "Nanoleaf"
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                lightingHeader
                brandPicker
                brandContent
                lightingFooter
            }
            .padding(20)
        }
        .frame(width: 340)
        .background(.black.opacity(0.82), in: .rect(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.10), lineWidth: 1)
        )
        .foregroundStyle(.white)
    }

    private var lightingHeader: some View {
        Text("LIGHTING")
            .font(Velo.display(14))
            .tracking(1.6)
            .foregroundStyle(.white.opacity(0.45))
    }

    private var brandPicker: some View {
        HStack(spacing: 4) {
            ForEach(LightBrand.allCases, id: \.self) { b in
                Button(b.rawValue) { brand = b }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .opacity(brand == b ? 1.0 : 0.4)
            }
        }
    }

    @ViewBuilder
    private var brandContent: some View {
        switch brand {
        case .hue:
            HueSettingsView(hue: model.hue)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .lifx:
            LifxSettingsView(state: model.lifx)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .nanoleaf:
            NanoleafSettingsView(state: model.nanoleaf)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var lightingFooter: some View {
        Text("L close · M controls")
            .font(Velo.label(12))
            .foregroundStyle(.white.opacity(0.3))
    }
}
