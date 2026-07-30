import SwiftUI

/// Nanoleaf setup and sync controls, embedded in the Lighting panel.
struct NanoleafSettingsView: View {
    @Bindable var state: NanoleafState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            statusRow
            deviceList
            actionArea
        }
    }

    // MARK: - Status

    @ViewBuilder
    private var statusRow: some View {
        switch state.phase {
        case .idle:
            EmptyView()
        case .searching:
            HStack(spacing: 6) {
                ProgressView().controlSize(.regular)
                caption("Searching network...")
            }
        case .foundUnpaired(let countdown):
            VStack(alignment: .leading, spacing: 4) {
                Text("Device found")
                    .font(Velo.label(14))
                    .foregroundStyle(.white.opacity(0.8))
                caption("Hold the power button on your Nanoleaf for 5-7 seconds until the lights flash, then release.")
                HStack(spacing: 6) {
                    ProgressView().controlSize(.regular)
                    Text("Waiting for pairing... \(countdown)s")
                        .font(Velo.light(13))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        case .streaming:
            HStack(spacing: 6) {
                Circle().fill(.green).frame(width: 8, height: 8)
                Text("Streaming")
                    .font(Velo.light(14))
                    .foregroundStyle(.white.opacity(0.8))
            }
        case .error(let msg):
            Text(msg)
                .font(Velo.light(14))
                .foregroundStyle(.red.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        case .paired:
            EmptyView()
        }
    }

    // MARK: - Device list

    @ViewBuilder
    private var deviceList: some View {
        if !state.devices.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(state.devices) { dev in
                    deviceRow(dev)
                }
            }
        }
    }

    private func deviceRow(_ dev: NanoleafCredentials) -> some View {
        HStack {
            Button {
                state.toggleSync(dev)
            } label: {
                HStack {
                    Text(dev.name)
                        .font(Velo.light(14))
                    Spacer()
                    if dev.syncOn {
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
            .opacity(dev.syncOn ? 1.0 : 0.6)

            Button("Unpair") {
                state.forgetDevice(dev.deviceId)
            }
            .buttonStyle(.link)
            .font(Velo.light(12))
            .foregroundStyle(.red.opacity(0.6))
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionArea: some View {
        switch state.phase {
        case .idle:
            scanButton("Scan for Nanoleaf")
        case .searching:
            cancelButton
        case .foundUnpaired:
            cancelButton
        case .paired:
            pairedControls
        case .streaming:
            streamingControls
        case .error:
            Button("OK") { state.dismiss() }
                .buttonStyle(.bordered)
                .controlSize(.regular)
        }
    }

    private var pairedControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            if state.controller.hasSyncableDevices() {
                NanoleafLightControl(state: state)

                Button("Start Sync") {
                    state.startSync()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            } else {
                caption("Select a device to enable control.")
            }

            scanButton("Add Another Device")
            forgetAllButton
        }
    }

    private var streamingControls: some View {
        VStack(alignment: .leading, spacing: 6) {
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

            forgetAllButton
        }
    }

    // MARK: - Buttons

    private func scanButton(_ label: String) -> some View {
        Button(label) {
            state.startScan()
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }

    private var cancelButton: some View {
        Button("Cancel") {
            state.cancelPairing()
        }
        .buttonStyle(.link)
        .font(Velo.light(13))
        .foregroundStyle(.white.opacity(0.5))
    }

    private var forgetAllButton: some View {
        Button("Forget All Devices") {
            state.forgetAll()
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

// MARK: - Light control (scenes + brightness)

private struct NanoleafLightControl: View {
    let state: NanoleafState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Light Control")
                .font(Velo.label(13))
                .foregroundStyle(.white.opacity(0.5))

            let columns = [GridItem(.flexible()), GridItem(.flexible())]
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(NanoScene.all) { scene in
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
                        state.controller.setStaticState(bri: state.brightness)
                    }
                })
            }
        }
    }

    private func applyScene(_ scene: NanoScene) {
        if !scene.on {
            state.controller.setStaticState(on: false)
        } else {
            state.controller.setStaticState(on: true, bri: state.brightness,
                                             hue: scene.hue, sat: scene.sat)
        }
    }
}

// MARK: - Scenes

private struct NanoScene: Identifiable {
    let id: String
    let label: String
    let dotColor: Color
    let on: Bool
    var hue: Float?
    var sat: Float?

    static let all: [NanoScene] = [
        NanoScene(id: "off",         label: "Off",         dotColor: Color(white: 0.4), on: false),
        NanoScene(id: "cool_white",  label: "Cool White",  dotColor: Color(red: 0.83, green: 0.89, blue: 1.0), on: true, hue: 210, sat: 0.2),
        NanoScene(id: "warm_white",  label: "Warm White",  dotColor: Color(red: 1.0, green: 0.87, blue: 0.63), on: true, hue: 40, sat: 0.5),
        NanoScene(id: "candlelight", label: "Candlelight", dotColor: Color(red: 1.0, green: 0.69, blue: 0.31), on: true, hue: 30, sat: 0.8),
        NanoScene(id: "red",         label: "Red",         dotColor: Color(red: 1.0, green: 0.19, blue: 0.19), on: true, hue: 0, sat: 1.0),
        NanoScene(id: "blue",        label: "Blue",        dotColor: Color(red: 0.19, green: 0.38, blue: 1.0), on: true, hue: 240, sat: 1.0),
        NanoScene(id: "green",       label: "Green",       dotColor: Color(red: 0.19, green: 0.87, blue: 0.38), on: true, hue: 120, sat: 1.0),
        NanoScene(id: "purple",      label: "Purple",      dotColor: Color(red: 0.56, green: 0.19, blue: 1.0), on: true, hue: 270, sat: 1.0),
    ]
}

// MARK: - State

@Observable
final class NanoleafState: @unchecked Sendable {

    enum Phase: Equatable {
        case idle, searching, foundUnpaired(countdown: Int), paired, streaming, error(String)
    }

    var phase: Phase = .idle
    var devices: [NanoleafCredentials] = []
    var brightness: Float = 1.0
    var showingAdvanced = false

    let controller = NanoleafController()

    init() {
        devices = controller.pairedDevices()
        syncPhase(controller.state)

        controller.onStateChange = { [weak self] state in
            guard let self else { return }
            self.devices = self.controller.pairedDevices()
            self.syncPhase(state)
        }
    }

    func startScan() {
        controller.search()
    }

    func cancelPairing() {
        controller.cancelPairing()
    }

    func toggleSync(_ dev: NanoleafCredentials) {
        let newVal = !dev.syncOn
        controller.setDeviceSyncOn(deviceId: dev.deviceId, on: newVal)
        if let idx = devices.firstIndex(where: { $0.deviceId == dev.deviceId }) {
            devices[idx].syncOn = newVal
        }
    }

    func startSync() {
        controller.startSync()
    }

    func stopSync() {
        controller.stopSync()
    }

    func forgetDevice(_ deviceId: String) {
        controller.forgetDevice(deviceId: deviceId)
        devices.removeAll(where: { $0.deviceId == deviceId })
    }

    func forgetAll() {
        controller.forgetAll()
        devices = []
    }

    func dismiss() {
        phase = devices.isEmpty ? .idle : .paired
    }

    private func syncPhase(_ s: NanoleafController.State) {
        switch s {
        case .idle: phase = .idle
        case .searching: phase = .searching
        case .foundUnpaired(let cd): phase = .foundUnpaired(countdown: cd)
        case .paired: phase = .paired
        case .streaming: phase = .streaming
        case .error(let msg): phase = .error(msg)
        }
    }
}
