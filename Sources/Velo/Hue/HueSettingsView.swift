import SwiftUI

/// The Hue setup and sync controls, embedded in the main ControlPanel.
struct HueSettingsView: View {
    @Bindable var hue: HueState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch hue.phase {
            case .idle:
                idleView
            case .discovering:
                ProgressView()
                    .controlSize(.small)
                Text("Searching for bridges...")
                    .font(Velo.light(12))
                    .foregroundStyle(.white.opacity(0.6))
            case .bridgesFound:
                bridgeList
            case .pairing:
                pairingView
            case .paired:
                areaSelection
            case .streaming:
                streamingView
            case .error(let msg):
                errorView(msg)
            }
        }
    }

    private var idleView: some View {
        VStack(alignment: .leading, spacing: 6) {
            if hue.store.load() != nil {
                Toggle("Light Sync", isOn: Binding(
                    get: { hue.controller.isEnabled },
                    set: { on in
                        if on {
                            hue.resumeStreaming()
                        } else {
                            hue.controller.disable(turnOff: true)
                            hue.phase = .idle
                        }
                    }
                ))
                .toggleStyle(.switch)

                caption("Paired. Toggle to sync lights with the music.")

                Button("Forget Bridge") {
                    hue.controller.disable(turnOff: true)
                    hue.store.clear()
                    hue.phase = .idle
                }
                .buttonStyle(.link)
                .font(Velo.light(11))
                .foregroundStyle(.red.opacity(0.7))
            } else {
                Button("Connect Hue Bridge") {
                    hue.startDiscovery()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                caption("Discover and pair a Philips Hue bridge on your network.")
            }
        }
    }

    private var bridgeList: some View {
        VStack(alignment: .leading, spacing: 6) {
            if hue.bridges.isEmpty {
                Text("No bridges found.")
                    .font(Velo.light(12))
                    .foregroundStyle(.white.opacity(0.6))
                Button("Retry") { hue.startDiscovery() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else {
                Text("Select a bridge:")
                    .font(Velo.light(12))
                    .foregroundStyle(.white.opacity(0.6))
                ForEach(hue.bridges) { bridge in
                    Button(bridge.ip) {
                        hue.startPairing(bridge: bridge)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            cancelButton
        }
    }

    private var pairingView: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text("Press the link button on your Hue bridge...")
                .font(Velo.light(12))
                .foregroundStyle(.white.opacity(0.8))
            if hue.countdown > 0 {
                Text("\(hue.countdown)s remaining")
                    .font(Velo.label(11))
                    .foregroundStyle(.white.opacity(0.5))
            }
            cancelButton
        }
    }

    private var areaSelection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Paired! Select an Entertainment Area:")
                .font(Velo.light(12))
                .foregroundStyle(.white.opacity(0.8))
            if hue.areas.isEmpty {
                Text("No Entertainment Areas configured on this bridge.\nCreate one in the Hue app first.")
                    .font(Velo.light(11))
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(hue.areas) { area in
                    Button("\(area.name) (\(area.channels.count) lights)") {
                        hue.startStreaming(area: area)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            cancelButton
        }
    }

    private var streamingView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
                Text("Streaming")
                    .font(Velo.light(12))
                    .foregroundStyle(.white.opacity(0.8))
            }
            caption("Lights synced to the music via BeatBus.")

            Button("Stop") {
                hue.controller.disable(turnOff: true)
                hue.phase = .idle
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func errorView(_ msg: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(msg)
                .font(Velo.light(12))
                .foregroundStyle(.red.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
            Button("OK") { hue.phase = .idle }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private var cancelButton: some View {
        Button("Cancel") { hue.phase = .idle }
            .buttonStyle(.link)
            .font(Velo.light(11))
            .foregroundStyle(.white.opacity(0.5))
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(Velo.light(11))
            .foregroundStyle(.white.opacity(0.5))
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - State machine

enum HuePhase: Equatable {
    case idle
    case discovering
    case bridgesFound
    case pairing
    case paired
    case streaming
    case error(String)

    static func == (lhs: HuePhase, rhs: HuePhase) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.discovering, .discovering),
             (.bridgesFound, .bridgesFound), (.pairing, .pairing),
             (.paired, .paired), (.streaming, .streaming): true
        case (.error(let a), .error(let b)): a == b
        default: false
        }
    }
}

@Observable
final class HueState: @unchecked Sendable {
    var phase: HuePhase = .idle
    var bridges: [HueBridge] = []
    var areas: [HueEntertainmentArea] = []
    var countdown = 0

    let controller = HueLightController()
    var store: HueCredentialStore { controller.store }

    init() {
        if store.syncEnabled, store.load() != nil {
            resumeStreaming()
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
                    phase = .paired
                }
            } catch {
                await MainActor.run {
                    phase = .error(error.localizedDescription)
                }
            }
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

    func resumeStreaming() {
        guard let creds = store.load(), let areaId = store.selectedAreaId else { return }
        Task {
            do {
                let areas = try await controller.setup.listAreas(creds)
                guard let area = areas.first(where: { $0.id == areaId }) ?? areas.first else {
                    await MainActor.run { phase = .error("Entertainment Area not found.") }
                    return
                }
                try await controller.enable(area: area)
                await MainActor.run { phase = .streaming }
            } catch {
                await MainActor.run {
                    phase = .error(error.localizedDescription)
                }
            }
        }
    }
}
