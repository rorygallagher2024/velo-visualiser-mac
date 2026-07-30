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

    private var activeLightIds: [String] = []

    var isEnabled: Bool { running }

    func enable(area: HueEntertainmentArea) async throws {
        guard !running else { return }
        guard let creds = store.load() else { throw HueSetupError.authFailed }
        guard !area.channels.isEmpty else { throw HueSetupError.bridgeError("Area has no light channels.") }

        store.selectedAreaId = area.id
        activeLightIds = area.lightIds

        VeloLog.write("hue", "Activating entertainment stream for area '\(area.name)' (\(area.channels.count) ch)")
        let ok = await setup.setStreamActive(creds, areaId: area.id, active: true)
        guard ok else { throw HueSetupError.bridgeError("Could not start the entertainment stream.") }
        VeloLog.write("hue", "Stream activated, connecting DTLS to \(creds.bridgeIp):2100")

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

    /// Stop the sender, close DTLS, deactivate the stream. When `turnOff` is
    /// true (user-initiated stop), also power the bulbs off via REST after
    /// releasing the entertainment session.
    func disable(turnOff: Bool = false) {
        guard running || senderThread != nil else { return }
        running = false
        senderThread = nil
        client?.close()
        client = nil
        store.syncEnabled = false

        if let creds = store.load(), let areaId = store.selectedAreaId {
            let ids = activeLightIds
            Task {
                _ = await setup.setStreamActive(creds, areaId: areaId, active: false)
                if turnOff && !ids.isEmpty {
                    await setup.controlLights(creds, lightIds: ids, on: false)
                }
            }
        }
    }

    private func startSender(channelIds: [Int]) {
        let thread = Thread { [weak self] in
            guard let self else { return }

            let cfg = LightingSettings.shared
            var flash: Float = 0
            var lastBeat = BeatBus.shared.beatCount
            var lastBeatNs: UInt64 = 0
            var smoothedBri: Float = cfg.restingGlow
            var rgb = [Float](repeating: 0, count: channelIds.count * 3)
            let frameNs: UInt64 = 1_000_000_000 / 50

            while self.running {
                let t0 = DispatchTime.now().uptimeNanoseconds

                let bus = BeatBus.shared
                let bc = bus.beatCount
                if bc != lastBeat {
                    let sinceLastBeat = Float(t0 - lastBeatNs) / 1_000_000_000
                    if sinceLastBeat >= cfg.beatCooldownSec {
                        flash = bus.loudness
                        lastBeatNs = t0
                    }
                    lastBeat = bc
                }
                flash *= Self.flashDecay

                Self.mapColors(
                    cfg: cfg,
                    count: channelIds.count,
                    bus: bus,
                    flash: flash,
                    smoothedBri: &smoothedBri,
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

    /// Spectrum -> per-channel RGB using the shared LightingSettings brightness
    /// curve. Colour follows the spectral balance (bass -> red, treble -> blue);
    /// brightness tracks energy and the beat flash.
    private static func mapColors(
        cfg: LightingSettings,
        count: Int,
        bus: BeatBus,
        flash: Float,
        smoothedBri: inout Float,
        out: inout [Float]
    ) {
        let low = bus.bassRatio
        let mid: Float = 0.5
        let high: Float = 1.0 - low

        let total = low + mid + high + 1e-3
        let centroid = ((mid * 0.5 + high) / total).clamped(0, 1)

        let rawBri = cfg.audioBrightnessValue(low: low, mid: mid, high: high, flash: flash)
        smoothedBri += (rawBri - smoothedBri) * cfg.brightnessSmoothing
        let value = smoothedBri
        let sat = max(0.6, audioSat - flash * 0.3)

        for i in 0..<count {
            let spread: Float = count > 1
                ? (Float(i) / Float(count - 1) - 0.5) * audioChannelSpread
                : 0
            let pos = (centroid + spread).clamped(0, 1)
            let hue = audioHueBass + (audioHueTreble - audioHueBass) * pos
            let (r, g, b) = hsvToRgb(h: hue, s: sat, v: value)
            out[i * 3] = r
            out[i * 3 + 1] = g
            out[i * 3 + 2] = b
        }
    }

    private static func hsvToRgb(h: Float, s: Float, v: Float) -> (Float, Float, Float) {
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

    private static let flashDecay: Float = 0.80
    private static let audioSat: Float = 0.92
    private static let audioHueBass: Float = 360
    private static let audioHueTreble: Float = 220
    private static let audioChannelSpread: Float = 0.22
}

private extension Float {
    func clamped(_ lo: Float, _ hi: Float) -> Float {
        Swift.min(Swift.max(self, lo), hi)
    }
}
