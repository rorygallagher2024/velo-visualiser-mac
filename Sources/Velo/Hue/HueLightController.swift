import Foundation

/// Ties the Hue pipeline to the audio: reads BeatBus on a dedicated ~50 Hz
/// sender thread and pushes colors over the DTLS stream.
///
/// The render loop never touches the network. The sender thread does all DTLS
/// work, matching Android's architecture exactly.
final class HueLightController: @unchecked Sendable {

    let store = HueCredentialStore()
    let setup = HueSetupManager()

    private var client: HueStreamClient?
    private var senderThread: Thread?
    private var running = false

    private(set) var packetsSent: Int64 { get { client?.packetsSent ?? 0 } set {} }
    private(set) var packetsFailed: Int64 { get { client?.packetsFailed ?? 0 } set {} }

    var isEnabled: Bool { running }

    func enable(area: HueEntertainmentArea) async throws {
        guard !running else { return }
        guard let creds = store.load() else { throw HueSetupError.authFailed }
        guard !area.channels.isEmpty else { throw HueSetupError.bridgeError("Area has no light channels.") }

        store.selectedAreaId = area.id

        let ok = await setup.setStreamActive(creds, areaId: area.id, active: true)
        guard ok else { throw HueSetupError.bridgeError("Could not start the entertainment stream.") }

        let channelIds = area.channels.map(\.channelId)
        let streamClient = HueStreamClient(
            bridgeIp: creds.bridgeIp,
            username: creds.username,
            clientKey: creds.clientKey,
            areaId: area.id
        )

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            streamClient.connect { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            }
        }

        client = streamClient
        running = true
        store.syncEnabled = true
        startSender(channelIds: channelIds)
    }

    func disable(turnOff: Bool = false) {
        guard running || senderThread != nil else { return }
        running = false
        senderThread = nil
        client?.close()
        client = nil
        store.syncEnabled = false

        if let creds = store.load(), let areaId = store.selectedAreaId {
            Task {
                _ = await setup.setStreamActive(creds, areaId: areaId, active: false)
                if turnOff {
                    // Can't easily get lightIds without the area; skip for now
                }
            }
        }
    }

    private func startSender(channelIds: [Int]) {
        let thread = Thread { [weak self] in
            guard let self else { return }

            var flash: Float = 0
            var lastBeat = BeatBus.shared.beatCount
            var rgb = [Float](repeating: 0, count: channelIds.count * 3)
            let frameNs: UInt64 = 1_000_000_000 / 50

            while self.running {
                let t0 = DispatchTime.now().uptimeNanoseconds

                let bus = BeatBus.shared
                let bc = bus.beatCount
                if bc != lastBeat {
                    flash = bus.loudness
                    lastBeat = bc
                }
                flash *= flashDecay

                self.mapColors(
                    count: channelIds.count,
                    low: bus.bassRatio,
                    level: bus.level,
                    flash: flash,
                    out: &rgb
                )

                self.client?.send(channelIds: channelIds, rgb: rgb)

                let elapsed = DispatchTime.now().uptimeNanoseconds - t0
                if elapsed < frameNs {
                    Thread.sleep(forTimeInterval: Double(frameNs - elapsed) / 1_000_000_000)
                }
            }
        }
        thread.name = "hue-sender"
        thread.qualityOfService = .userInteractive
        self.senderThread = thread
        thread.start()
    }

    /// Spectrum → per-channel RGB. Color follows bass balance (red → purple →
    /// blue); brightness tracks energy plus beat flash.
    private func mapColors(count: Int, low: Float, level: Float, flash: Float, out: inout [Float]) {
        let centroid = min(max(1 - low, 0), 1)
        let energy = min(max(level * 8, 0), 1)
        let drive = min(energy * 0.5 + flash * 1.5, 1)
        let value = sqrtf(max(drive, restingGlow))
        let sat = max(0.6, audioSat - flash * 0.3)

        for i in 0..<count {
            let spread: Float = count > 1
                ? (Float(i) / Float(count - 1) - 0.5) * channelSpread
                : 0
            let pos = min(max(centroid + spread, 0), 1)
            let hue = audioHueBass + (audioHueTreble - audioHueBass) * pos
            let (r, g, b) = hsvToRgb(h: hue, s: sat, v: value)
            out[i * 3] = r
            out[i * 3 + 1] = g
            out[i * 3 + 2] = b
        }
    }

    private func hsvToRgb(h: Float, s: Float, v: Float) -> (Float, Float, Float) {
        let hh = (((h.truncatingRemainder(dividingBy: 360)) + 360)
            .truncatingRemainder(dividingBy: 360)) / 60
        let c = v * s
        let x = c * (1 - abs(hh.truncatingRemainder(dividingBy: 2) - 1))
        let m = v - c
        var r: Float = 0, g: Float = 0, b: Float = 0
        switch Int(hh) {
        case 0: r = c; g = x
        case 1: r = x; g = c
        case 2: g = c; b = x
        case 3: g = x; b = c
        case 4: r = x; b = c
        default: r = c; b = x
        }
        return (r + m, g + m, b + m)
    }

    private let flashDecay: Float = 0.80
    private let restingGlow: Float = 0.08
    private let audioSat: Float = 0.92
    private let audioHueBass: Float = 360
    private let audioHueTreble: Float = 220
    private let channelSpread: Float = 0.22
}
