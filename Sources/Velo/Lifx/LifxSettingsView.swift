import SwiftUI

/// LIFX setup and sync controls, embedded in the Lighting section.
struct LifxSettingsView: View {
    @Bindable var state: LifxState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Scan button
            HStack(spacing: 8) {
                Button(state.bulbs.isEmpty ? "Scan for LIFX" : "Rescan") {
                    state.startScan()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(state.scanning)

                if state.scanning {
                    ProgressView().controlSize(.regular)
                }
            }

            if !state.bulbs.isEmpty {
                // Bulb list
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(state.bulbs) { bulb in
                        bulbRow(bulb)
                    }
                }

                if state.controller.hasSelectedBulbs() {
                    if state.syncing {
                        streamingSection
                    } else {
                        readySection
                    }
                } else if !state.syncing {
                    caption("Tap a bulb to select it for control.")
                }

                Button("Forget Bulbs") {
                    state.forgetAll()
                }
                .buttonStyle(.link)
                .font(Velo.light(13))
                .foregroundStyle(.red.opacity(0.7))
            } else if !state.scanning {
                caption("No LIFX bulbs found. Make sure bulbs are on the same network.")
            }
        }
    }

    // MARK: - Bulb row

    private func bulbRow(_ bulb: LifxBulb) -> some View {
        Button {
            state.toggleBulb(bulb)
        } label: {
            HStack {
                Text(bulb.label)
                    .font(Velo.light(14))
                Spacer()
                if bulb.isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: "circle")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .opacity(bulb.isSelected ? 1.0 : 0.6)
    }

    // MARK: - Ready (selected, not streaming)

    private var readySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            LifxLightControlSection(state: state)

            Button("Start Sync") {
                state.startSync()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
    }

    // MARK: - Streaming

    private var streamingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
                Text("Streaming")
                    .font(Velo.light(14))
                    .foregroundStyle(.white.opacity(0.8))
            }

            ReactivityPresets()

            Button("Advanced...") {
                state.showingAdvanced = true
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .popover(isPresented: $state.showingAdvanced) {
                AdvancedLightingView()
                    .frame(width: 280)
                    .padding()
            }

            Button("Stop") {
                state.stopSync()
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(Velo.light(13))
            .foregroundStyle(.white.opacity(0.5))
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Light control (scenes + brightness)

private struct LifxLightControlSection: View {
    let state: LifxState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Light Control")
                .font(Velo.label(13))
                .foregroundStyle(.white.opacity(0.5))

            let columns = [GridItem(.flexible()), GridItem(.flexible())]
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(LifxScene.all) { scene in
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
                    get: { Double(state.brightness) },
                    set: { state.brightness = Float($0) }
                ), in: 0.01...1.0, onEditingChanged: { editing in
                    if !editing {
                        state.controller.setStaticColor(brightness: state.brightness)
                    }
                })
            }
        }
    }

    private func applyScene(_ scene: LifxScene) {
        if !scene.on {
            state.controller.setStaticPower(on: false)
        } else {
            state.controller.setStaticPower(on: true)
            let kelvin = scene.mirek.map { 1_000_000 / $0 } ?? 3500
            state.controller.setStaticColor(
                hue: scene.hue,
                sat: scene.sat,
                brightness: state.brightness,
                kelvin: kelvin
            )
        }
    }
}

// MARK: - Scenes (same as Hue)

private struct LifxScene: Identifiable {
    let id: String
    let label: String
    let dotColor: Color
    let on: Bool
    var mirek: Int?
    var hue: Float?
    var sat: Float?

    static let all: [LifxScene] = [
        LifxScene(id: "off",         label: "Off",         dotColor: Color(white: 0.4), on: false),
        LifxScene(id: "cool_white",  label: "Cool White",  dotColor: Color(red: 0.83, green: 0.89, blue: 1.0), on: true, mirek: 250, hue: 210, sat: 0.2),
        LifxScene(id: "warm_white",  label: "Warm White",  dotColor: Color(red: 1.0, green: 0.87, blue: 0.63), on: true, mirek: 370, hue: 40, sat: 0.5),
        LifxScene(id: "candlelight", label: "Candlelight", dotColor: Color(red: 1.0, green: 0.69, blue: 0.31), on: true, mirek: 454, hue: 30, sat: 0.8),
        LifxScene(id: "red",         label: "Red",         dotColor: Color(red: 1.0, green: 0.19, blue: 0.19), on: true, hue: 0, sat: 1.0),
        LifxScene(id: "blue",        label: "Blue",        dotColor: Color(red: 0.19, green: 0.38, blue: 1.0), on: true, hue: 240, sat: 1.0),
        LifxScene(id: "green",       label: "Green",       dotColor: Color(red: 0.19, green: 0.87, blue: 0.38), on: true, hue: 120, sat: 1.0),
        LifxScene(id: "purple",      label: "Purple",      dotColor: Color(red: 0.56, green: 0.19, blue: 1.0), on: true, hue: 270, sat: 1.0),
    ]
}

// MARK: - State

@Observable
final class LifxState: @unchecked Sendable {
    var bulbs: [LifxBulb] = []
    var scanning = false
    var syncing = false
    var brightness: Float = 1.0
    var showingAdvanced = false

    let controller = LifxController()

    init() {
        bulbs = controller.cachedBulbs()
    }

    func startScan() {
        scanning = true
        controller.startDiscovery(
            onBulbFound: { [weak self] bulb in
                Task { @MainActor in
                    guard let self else { return }
                    if let idx = self.bulbs.firstIndex(where: { $0.mac == bulb.mac }) {
                        self.bulbs[idx] = bulb
                    } else {
                        self.bulbs.append(bulb)
                    }
                }
            },
            onFinished: { [weak self] in
                Task { @MainActor in self?.scanning = false }
            }
        )
    }

    func toggleBulb(_ bulb: LifxBulb) {
        let newState = !bulb.isSelected
        controller.setBulbSelected(ip: bulb.ip, selected: newState)
        if let idx = bulbs.firstIndex(where: { $0.mac == bulb.mac }) {
            bulbs[idx].isSelected = newState
        }

        if syncing && !controller.hasSelectedBulbs() {
            stopSync()
        }
    }

    func startSync() {
        guard controller.hasSelectedBulbs() else { return }
        controller.enableStreaming()
        syncing = true
    }

    func stopSync() {
        controller.disableStreaming()
        syncing = false
    }

    func forgetAll() {
        if syncing { stopSync() }
        controller.forgetBulbs()
        bulbs = []
    }
}
