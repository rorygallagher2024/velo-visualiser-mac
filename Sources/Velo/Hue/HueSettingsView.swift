import SwiftUI

/// The Hue setup and sync controls, embedded in the main ControlPanel.
struct HueSettingsView: View {
    @Bindable var hue: HueState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch hue.phase {
            case .unpaired:
                unpairedView
            case .discovering:
                spinnerView("Searching for bridges...")
            case .bridgesFound:
                bridgeList
            case .pairing:
                pairingView
            case .ready:
                readyView
            case .streaming:
                streamingView
            case .error(let msg):
                errorView(msg)
            }
        }
    }

    // MARK: - Unpaired

    private var unpairedView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button("Connect Hue Bridge") {
                hue.startDiscovery()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            caption("Discover and pair a Philips Hue bridge on your network.")
        }
    }

    // MARK: - Discovery

    private func spinnerView(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.regular)
                Text(text)
                    .font(Velo.light(14))
                    .foregroundStyle(.white.opacity(0.6))
            }
            cancelButton
        }
    }

    private var bridgeList: some View {
        VStack(alignment: .leading, spacing: 6) {
            if hue.bridges.isEmpty {
                Text("No bridges found.")
                    .font(Velo.light(14))
                    .foregroundStyle(.white.opacity(0.6))
                Button("Retry") { hue.startDiscovery() }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
            } else {
                Text("Select a bridge:")
                    .font(Velo.light(14))
                    .foregroundStyle(.white.opacity(0.6))
                ForEach(hue.bridges) { bridge in
                    Button(bridge.ip) {
                        hue.startPairing(bridge: bridge)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
            }
            cancelButton
        }
    }

    // MARK: - Pairing

    private var pairingView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.regular)
                Text("Press the link button on your Hue bridge...")
                    .font(Velo.light(14))
                    .foregroundStyle(.white.opacity(0.8))
            }
            if hue.countdown > 0 {
                Text("\(hue.countdown)s remaining")
                    .font(Velo.label(15))
                    .foregroundStyle(.white.opacity(0.5))
            }
            cancelButton
        }
    }

    // MARK: - Ready (paired, not streaming)

    private var readyView: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Entertainment areas
            if hue.areas.isEmpty {
                // Only reachable once the bridge has answered, so this now
                // means what it says. A failed lookup lands in .error instead.
                Text("The bridge reports no Entertainment Areas.\n"
                     + "Create one in the Hue app, then check again.")
                    .font(Velo.light(13))
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
                // Without this the only listed action is Forget Bridge, which
                // is a destructive answer to what is usually a transient miss.
                Button("Check Again") { hue.retryLoadAreas() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else if hue.areas.count == 1 {
                if let area = hue.areas.first {
                    Text("\(area.name) (\(area.channels.count) lights)")
                        .font(Velo.light(14))
                        .foregroundStyle(.white.opacity(0.7))
                        .onAppear { hue.selectArea(area) }
                }
            } else {
                Picker("Entertainment Area", selection: Binding(
                    get: { hue.selectedAreaId ?? "" },
                    set: { id in
                        if let area = hue.areas.first(where: { $0.id == id }) {
                            hue.selectArea(area)
                        }
                    }
                )) {
                    ForEach(hue.areas) { area in
                        Text("\(area.name) (\(area.channels.count) lights)")
                            .tag(area.id)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.regular)
            }

            // Light control (when an area is selected)
            if let areaId = hue.selectedAreaId,
               let area = hue.areas.first(where: { $0.id == areaId }) {
                LightControlSection(hue: hue, area: area)

                Button("Start Sync") {
                    hue.startStreaming(area: area)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }

            forgetButton
        }
    }

    // MARK: - Streaming

    private var streamingView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
                Text("Streaming")
                    .font(Velo.light(14))
                    .foregroundStyle(.white.opacity(0.8))
            }

            areaPickerCompact

            ReactivityPresets()

            Button("Advanced...") {
                hue.showingAdvanced = true
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .popover(isPresented: Binding(
                get: { hue.showingAdvanced },
                set: { hue.showingAdvanced = $0 }
            )) {
                AdvancedLightingView()
                    .frame(width: 280)
                    .padding()
            }

            HStack(spacing: 8) {
                Button("Stop") {
                    hue.stopStreaming()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                forgetButton
            }
        }
    }

    /// Compact area picker: a Picker dropdown usable from both ready and streaming states.
    private var areaPickerCompact: some View {
        Group {
            if hue.areas.count > 1 {
                Picker("Area", selection: Binding(
                    get: { hue.selectedAreaId ?? "" },
                    set: { id in
                        if let area = hue.areas.first(where: { $0.id == id }) {
                            hue.switchArea(area)
                        }
                    }
                )) {
                    ForEach(hue.areas) { area in
                        Text("\(area.name) (\(area.channels.count) lights)")
                            .tag(area.id)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.regular)
            }
        }
    }

    // MARK: - Error

    private func errorView(_ msg: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(msg)
                .font(Velo.light(14))
                .foregroundStyle(.red.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if hue.store.load() != nil {
                    Button("Try Again") { hue.retryLoadAreas() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                }
                Button("OK") {
                    hue.phase = hue.store.load() != nil ? .ready : .unpaired
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
        }
    }

    // MARK: - Helpers

    private var cancelButton: some View {
        Button("Cancel") {
            hue.phase = hue.store.load() != nil ? .ready : .unpaired
        }
        .buttonStyle(.link)
        .font(Velo.light(13))
        .foregroundStyle(.white.opacity(0.5))
    }

    private var forgetButton: some View {
        Button("Forget Bridge") {
            hue.forgetBridge()
        }
        .buttonStyle(.link)
        .font(Velo.light(13))
        .foregroundStyle(.red.opacity(0.7))
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(Velo.light(13))
            .foregroundStyle(.white.opacity(0.5))
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Light Control (scenes + brightness)

private struct LightControlSection: View {
    let hue: HueState
    let area: HueEntertainmentArea

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Light Control")
                .font(Velo.label(15))
                .foregroundStyle(.white.opacity(0.5))

            let columns = [GridItem(.flexible()), GridItem(.flexible())]
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(LightScene.all) { scene in
                    Button {
                        applyScene(scene)
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(scene.dotColor)
                                .frame(width: 8, height: 8)
                            Text(scene.label)
                                .font(Velo.light(13))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
            }

            HStack(spacing: 8) {
                Text("Brightness")
                    .font(Velo.light(13))
                    .foregroundStyle(.white.opacity(0.5))
                Slider(value: Binding(
                    get: { Double(hue.brightness) / 100.0 },
                    set: { hue.brightness = Int($0 * 100) }
                ), in: 0.01...1.0, onEditingChanged: { editing in
                    if !editing { applyBrightness() }
                })
            }
        }
    }

    private func applyScene(_ scene: LightScene) {
        guard let creds = hue.store.load() else { return }
        Task {
            if !scene.on {
                await hue.controller.setup.controlLights(creds, lightIds: area.lightIds, on: false)
            } else {
                await hue.controller.setup.controlLights(
                    creds,
                    lightIds: area.lightIds,
                    on: true,
                    brightness: max(hue.brightness, 1),
                    mirek: scene.mirek,
                    x: scene.x,
                    y: scene.y
                )
            }
        }
    }

    private func applyBrightness() {
        guard let creds = hue.store.load() else { return }
        Task {
            await hue.controller.setup.controlLights(
                creds,
                lightIds: area.lightIds,
                on: true,
                brightness: max(hue.brightness, 1)
            )
        }
    }
}

// MARK: - Light Scenes (matching Android)

private struct LightScene: Identifiable {
    let id: String
    let label: String
    let dotColor: Color
    let on: Bool
    var mirek: Int?
    var x: Double?
    var y: Double?

    static let all: [LightScene] = [
        LightScene(id: "off",         label: "Off",         dotColor: Color(white: 0.4), on: false),
        LightScene(id: "cool_white",  label: "Cool White",  dotColor: Color(red: 0.83, green: 0.89, blue: 1.0), on: true, mirek: 250),
        LightScene(id: "warm_white",  label: "Warm White",  dotColor: Color(red: 1.0, green: 0.87, blue: 0.63), on: true, mirek: 370),
        LightScene(id: "candlelight", label: "Candlelight", dotColor: Color(red: 1.0, green: 0.69, blue: 0.31), on: true, mirek: 454),
        LightScene(id: "red",         label: "Red",         dotColor: Color(red: 1.0, green: 0.19, blue: 0.19), on: true, x: 0.675, y: 0.322),
        LightScene(id: "blue",        label: "Blue",        dotColor: Color(red: 0.19, green: 0.38, blue: 1.0), on: true, x: 0.167, y: 0.04),
        LightScene(id: "green",       label: "Green",       dotColor: Color(red: 0.19, green: 0.87, blue: 0.38), on: true, x: 0.2, y: 0.68),
        LightScene(id: "purple",      label: "Purple",      dotColor: Color(red: 0.56, green: 0.19, blue: 1.0), on: true, x: 0.27, y: 0.12),
    ]
}

// MARK: - Reactivity Presets

struct ReactivityPresets: View {
    @State private var preset = LightingSettings.shared.preset

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Reactivity")
                .font(Velo.label(15))
                .foregroundStyle(.white.opacity(0.5))
            HStack(spacing: 4) {
                presetButton("Smooth", .smooth)
                presetButton("Reactive", .reactive)
                presetButton("Strobe", .strobe)
            }
        }
    }

    private func presetButton(_ label: String, _ p: LightingSettings.Preset) -> some View {
        Button(label) {
            LightingSettings.shared.applyPreset(p)
            LightingSettings.shared.save()
            preset = p
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .opacity(preset == p ? 1.0 : 0.5)
    }
}

// MARK: - Advanced Tuning

struct AdvancedLightingView: View {
    @State private var colourSplit: Double
    @State private var glow: Double
    @State private var brightness: Double
    @State private var flash: Double

    private let cfg = LightingSettings.shared

    init() {
        let c = LightingSettings.shared
        _colourSplit = State(initialValue: Double(c.colourSplit))
        _glow = State(initialValue: Double(c.restingGlow))
        _brightness = State(initialValue: Double(c.audioBrightness))
        _flash = State(initialValue: Double(c.audioFlash))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Advanced Light Tuning")
                .font(Velo.label(15))
                .foregroundStyle(.white.opacity(0.8))

            Text("These sliders fine-tune how the lights react to the music. Moving any slider switches the preset to Custom.")
                .font(Velo.light(13))
                .foregroundStyle(.white.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)

            slider("Colour Split", value: $colourSplit, hint: "Bass \u{2192} red, treble \u{2192} blue crossover") {
                cfg.colourSplit = Float(colourSplit)
                markCustom()
            }
            slider("Resting Glow", value: $glow, hint: "How lit the lights sit between beats") {
                cfg.restingGlow = Float(glow)
                markCustom()
            }
            slider("Audio Brightness", value: $brightness, hint: "How much sustained volume lights the base") {
                cfg.audioBrightness = Float(brightness)
                markCustom()
            }
            slider("Beat Flash", value: $flash, hint: "How hard a beat pops above the base") {
                cfg.audioFlash = Float(flash)
                markCustom()
            }

            Button("Reset to Defaults") {
                cfg.resetToDefaults()
                cfg.save()
                colourSplit = Double(cfg.colourSplit)
                glow = Double(cfg.restingGlow)
                brightness = Double(cfg.audioBrightness)
                flash = Double(cfg.audioFlash)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
    }

    private func slider(
        _ label: String,
        value: Binding<Double>,
        hint: String,
        onChange: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(Velo.label(15))
                .foregroundStyle(.white.opacity(0.6))
            Slider(value: value, in: 0...1, onEditingChanged: { editing in
                if !editing { onChange() }
            })
            Text(hint)
                .font(Velo.light(12))
                .foregroundStyle(.white.opacity(0.3))
        }
    }

    private func markCustom() {
        cfg.markCustom()
        cfg.save()
    }
}

// MARK: - State machine

enum HuePhase: Equatable {
    case unpaired
    case discovering
    case bridgesFound
    case pairing
    case ready          // paired, areas loaded, not streaming
    case streaming
    case error(String)

    static func == (lhs: HuePhase, rhs: HuePhase) -> Bool {
        switch (lhs, rhs) {
        case (.unpaired, .unpaired), (.discovering, .discovering),
             (.bridgesFound, .bridgesFound), (.pairing, .pairing),
             (.ready, .ready), (.streaming, .streaming): true
        case (.error(let a), .error(let b)): a == b
        default: false
        }
    }
}

@Observable
final class HueState: @unchecked Sendable {
    var phase: HuePhase = .unpaired
    var bridges: [HueBridge] = []
    var areas: [HueEntertainmentArea] = []
    var countdown = 0
    var selectedAreaId: String?
    var brightness: Int = 80
    var showingAdvanced = false

    let controller = HueLightController()
    var store: HueCredentialStore { controller.store }

    init() {
        LightingSettings.shared.restore()
        selectedAreaId = store.selectedAreaId

        if store.load() != nil {
            if store.syncEnabled {
                resumeStreaming()
            } else {
                loadAreasForReady()
            }
        }
    }

    func startDiscovery() {
        phase = .discovering
        Task {
            let found = await controller.setup.discoverBridges()
            await MainActor.run {
                bridges = found
                phase = .bridgesFound
            }
        }
    }

    func startPairing(bridge: HueBridge) {
        phase = .pairing
        countdown = 30
        Task {
            do {
                let creds = try await controller.setup.pair(
                    bridgeIp: bridge.ip,
                    onCountdown: { [weak self] sec in
                        Task { @MainActor in self?.countdown = sec }
                    }
                )
                store.save(creds)
                let areas = try await controller.setup.listAreas(creds)
                await MainActor.run {
                    self.areas = areas
                    if let first = areas.first {
                        selectArea(first)
                    }
                    phase = .ready
                }
            } catch {
                await MainActor.run {
                    phase = .error(error.localizedDescription)
                }
            }
        }
    }

    func selectArea(_ area: HueEntertainmentArea) {
        selectedAreaId = area.id
        store.selectedAreaId = area.id
    }

    /// Switch area while streaming: stop the current stream, start on the new area.
    func switchArea(_ area: HueEntertainmentArea) {
        selectArea(area)
        if controller.isEnabled {
            controller.disable(turnOff: false)
            startStreaming(area: area)
        }
    }

    func startStreaming(area: HueEntertainmentArea) {
        Task {
            do {
                try await controller.enable(area: area)
                await MainActor.run { phase = .streaming }
            } catch {
                await MainActor.run {
                    phase = .error(error.localizedDescription)
                }
            }
        }
    }

    func stopStreaming() {
        controller.disable(turnOff: true)
        phase = .ready
    }

    func forgetBridge() {
        controller.disable(turnOff: true)
        store.clear()
        areas = []
        selectedAreaId = nil
        phase = .unpaired
    }

    func resumeStreaming() {
        guard let creds = store.load(), let areaId = store.selectedAreaId else { return }
        Task {
            do {
                let (areas, updated) = try await controller.setup
                    .listAreasResolvingAddress(creds)
                if let updated { store.save(updated) }
                guard let area = areas.first(where: { $0.id == areaId }) ?? areas.first else {
                    // Reached the bridge and it really does have none.
                    await MainActor.run {
                        self.areas = areas
                        phase = .error("The bridge has no Entertainment Area. "
                                       + "Create one in the Hue app.")
                    }
                    return
                }
                await MainActor.run { self.areas = areas }
                try await controller.enable(area: area)
                await MainActor.run { phase = .streaming }
            } catch {
                await MainActor.run {
                    phase = .error(error.localizedDescription)
                }
            }
        }
    }

    /// Load areas and move to .ready when we have saved credentials but aren't streaming.
    /// Re-run the area lookup after a failure.
    ///
    /// The startup lookup fires from `init`, which on macOS is exactly when a
    /// Local Network prompt may still be unanswered — and an ad-hoc signed
    /// build gets a fresh cdhash on every version, so that grant is dropped
    /// each time the app in /Applications is replaced. Without a retry the only
    /// listed way out is Forget Bridge, which is why re-pairing looked like the
    /// cure: it was simply the one button that ran a network call again.
    func retryLoadAreas() {
        phase = .ready
        loadAreasForReady()
    }

    private func loadAreasForReady() {
        guard let creds = store.load() else { return }
        Task {
            do {
                let (areas, updated) = try await controller.setup
                    .listAreasResolvingAddress(creds)
                if let updated { store.save(updated) }
                await MainActor.run {
                    self.areas = areas
                    phase = .ready
                }
            } catch {
                // Going .ready with an empty list told the user they had no
                // Entertainment Areas, when the truth was that we never managed
                // to ask. Show what actually went wrong instead.
                VeloLog.write("hue", "could not load areas: \(error.localizedDescription)")
                await MainActor.run {
                    phase = .error(error.localizedDescription)
                }
            }
        }
    }
}
