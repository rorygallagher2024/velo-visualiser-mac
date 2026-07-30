import Foundation

/// Nanoleaf LAN controller: mDNS discovery, REST pairing, multi-device
/// External Control v2 UDP streaming at ~40 fps, and static scene/power
/// control. Matches Android's NanoleafController feature-for-feature.
final class NanoleafController: @unchecked Sendable {

    let store = NanoleafStore()

    enum State: Equatable {
        case idle
        case searching
        /// Found unpaired device(s). Instruction shown, pairing poll running silently.
        case foundUnpaired(countdown: Int)
        case paired
        case streaming
        case error(String)
    }

    private(set) var state: State = .idle
    var onStateChange: ((State) -> Void)?

    fileprivate let lock = NSLock()
    private var devices: [NanoleafCredentials] = []

    // Discovery
    private var browser: NetServiceBrowser?
    private var browserDelegate: BrowserDelegate?
    fileprivate var discovered: [String: DiscoveredDevice] = [:]
    private var settleTimer: DispatchWorkItem?

    // Pairing
    private var pairingThread: Thread?

    // Streaming
    private var streaming = false
    private var senderThread: Thread?

    // Per-device streaming state
    private struct StreamTarget {
        let creds: NanoleafCredentials
        let panelIds: [Int]
        let udpPort: Int
    }

    init() {
        devices = store.loadAll()
        if !devices.isEmpty {
            state = .paired
        }
    }

    // MARK: - Discovery

    func search() {
        lock.lock()
        discovered.removeAll()
        lock.unlock()
        setState(.searching)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let del = BrowserDelegate(controller: self)
            let b = NetServiceBrowser()
            b.delegate = del
            self.browserDelegate = del
            self.browser = b
            b.searchForServices(ofType: "_nanoleafapi._tcp.", inDomain: "local.")

            self.settleTimer?.cancel()
            let settle = DispatchWorkItem { [weak self] in self?.finishSearch() }
            self.settleTimer = settle
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: settle)
        }
    }

    private func finishSearch() {
        browser?.stop()
        browser = nil
        browserDelegate = nil

        lock.lock()
        let found = discovered
        lock.unlock()

        let existing = Set(devices.map(\.deviceId))
        let strangers = found.filter { !existing.contains($0.key) }

        if !strangers.isEmpty {
            openPairingWindow(Array(strangers.values))
        } else if !devices.isEmpty {
            reconcileIPs(found)
            setState(.paired)
        } else {
            setState(.idle)
        }
    }

    private func reconcileIPs(_ found: [String: DiscoveredDevice]) {
        var changed = false
        for (i, dev) in devices.enumerated() {
            if let disc = found[dev.deviceId], disc.ip != dev.ip {
                devices[i].ip = disc.ip
                changed = true
            }
        }
        if changed { store.save(devices) }
    }

    // MARK: - Pairing

    private static let pairingWindowSec = 90
    private static let pairPollSec: TimeInterval = 2.0

    private var pairingCancelled = false

    private func openPairingWindow(_ candidates: [DiscoveredDevice]) {
        pairingCancelled = false
        setState(.foundUnpaired(countdown: Self.pairingWindowSec))

        let thread = Thread { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(Double(Self.pairingWindowSec))
            var paired: [String] = []

            while Date() < deadline && !self.pairingCancelled {
                let remaining = Int(deadline.timeIntervalSinceNow)
                self.setState(.foundUnpaired(countdown: max(0, remaining)))

                for candidate in candidates where !paired.contains(candidate.id) {
                    if let token = NanoleafApi.requestToken(host: candidate.ip, port: candidate.port) {
                        let name = NanoleafApi.fetchName(host: candidate.ip, port: candidate.port, token: token) ?? candidate.name
                        let creds = NanoleafCredentials(
                            ip: candidate.ip,
                            token: token,
                            port: candidate.port,
                            deviceId: candidate.id,
                            name: name,
                            syncOn: true
                        )
                        self.lock.lock()
                        if let idx = self.devices.firstIndex(where: { $0.deviceId == creds.deviceId }) {
                            self.devices[idx] = creds
                        } else {
                            self.devices.append(creds)
                        }
                        self.store.upsert(creds)
                        self.lock.unlock()
                        paired.append(candidate.id)
                        VeloLog.write("nanoleaf", "Paired: \(name)")
                    }
                }

                if paired.count == candidates.count { break }

                Thread.sleep(forTimeInterval: Self.pairPollSec)
            }

            if !paired.isEmpty || !self.devices.isEmpty {
                self.setState(.paired)
            } else {
                self.setState(.error("No device paired. Make sure you held the power button until the lights flashed."))
            }
        }
        thread.name = "nanoleaf-pair"
        pairingThread = thread
        thread.start()
    }

    func cancelPairing() {
        pairingCancelled = true
        pairingThread = nil
        setState(devices.isEmpty ? .idle : .paired)
    }

    // MARK: - Device management

    func pairedDevices() -> [NanoleafCredentials] {
        lock.lock(); defer { lock.unlock() }
        return devices
    }

    func setDeviceSyncOn(deviceId: String, on: Bool) {
        lock.lock()
        guard let idx = devices.firstIndex(where: { $0.deviceId == deviceId }) else {
            lock.unlock(); return
        }
        devices[idx].syncOn = on
        store.save(devices)
        lock.unlock()
    }

    func forgetDevice(deviceId: String) {
        lock.lock()
        devices.removeAll(where: { $0.deviceId == deviceId })
        store.remove(deviceId: deviceId)
        let remaining = devices
        lock.unlock()
        if remaining.isEmpty {
            setState(.idle)
        }
    }

    func forgetAll() {
        if streaming { stopSync() }
        lock.lock()
        devices.removeAll()
        store.clear()
        lock.unlock()
        setState(.idle)
    }

    func hasSyncableDevices() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return devices.contains(where: \.syncOn)
    }

    // MARK: - Static control

    func setStaticState(on: Bool? = nil, bri: Float? = nil, hue: Float? = nil, sat: Float? = nil) {
        let targets = pairedDevices()
        DispatchQueue.global(qos: .userInitiated).async {
            for dev in targets {
                NanoleafApi.setState(host: dev.ip, port: dev.port, token: dev.token,
                                     on: on, bri: bri, hue: hue, sat: sat)
            }
        }
    }

    // MARK: - Streaming

    func startSync() {
        guard !streaming else { return }

        let syncTargets = pairedDevices().filter(\.syncOn)
        guard !syncTargets.isEmpty else { return }

        streaming = true
        store.syncEnabled = true
        setState(.streaming)

        let thread = Thread { [weak self] in
            guard let self else { return }

            var targets: [StreamTarget] = []
            for dev in syncTargets {
                guard let panelIds = NanoleafApi.fetchPanelIds(host: dev.ip, port: dev.port, token: dev.token),
                      !panelIds.isEmpty,
                      let udpPort = NanoleafApi.enableExtControl(host: dev.ip, port: dev.port, token: dev.token)
                else {
                    VeloLog.write("nanoleaf", "Failed to prepare stream for \(dev.name)")
                    continue
                }
                targets.append(StreamTarget(creds: dev, panelIds: panelIds, udpPort: udpPort))
            }

            guard !targets.isEmpty else {
                self.streaming = false
                self.setState(.error("Could not connect to any Nanoleaf device."))
                return
            }

            let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard fd >= 0 else {
                self.streaming = false
                self.setState(.error("Could not create UDP socket."))
                return
            }
            defer { Darwin.close(fd) }

            // Power on all targets
            for t in targets {
                NanoleafApi.setState(host: t.creds.ip, port: t.creds.port, token: t.creds.token, on: true)
            }

            let cfg = LightingSettings.shared
            var flash: Float = 0
            var lastBeat = BeatBus.shared.beatCount
            var lastBeatNs: UInt64 = 0
            var smoothedBri: Float = cfg.restingGlow
            var currentHue: Float = Self.audioHueBass
            var currentSat: Float = Self.satAudio
            let frameNs: UInt64 = 25_000_000 // 25ms = ~40fps

            while self.streaming {
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

                let low = bus.bassRatio
                let mid: Float = 0.5
                let high: Float = 1.0 - low

                let trebleWeight = (high + mid * 0.5) / (low + mid + high + 0.001)
                let targetHue = Self.audioHueBass + (Self.audioHueTreble - Self.audioHueBass) * trebleWeight.clamped(0, 1)
                if flash > 0.01 {
                    currentHue += 0.3 * (targetHue - currentHue)
                    currentSat += 0.3 * (Self.satAudio - currentSat)
                }

                let rawBri = cfg.audioBrightnessValue(low: low, mid: mid, high: high, flash: flash)
                smoothedBri += (rawBri - smoothedBri) * cfg.brightnessSmoothing
                let rgb = Self.hsvToRgb(h: currentHue, s: currentSat, v: smoothedBri)

                for target in targets {
                    Self.sendFrame(fd: fd, target: target, r: rgb.r, g: rgb.g, b: rgb.b)
                }

                let elapsed = DispatchTime.now().uptimeNanoseconds - t0
                if elapsed < frameNs {
                    Thread.sleep(forTimeInterval: Double(frameNs - elapsed) / 1_000_000_000)
                }
            }

            // Power off
            for t in targets {
                NanoleafApi.setState(host: t.creds.ip, port: t.creds.port, token: t.creds.token, on: false)
            }
        }
        thread.name = "nanoleaf-sender"
        thread.qualityOfService = .userInteractive
        senderThread = thread
        thread.start()
    }

    func stopSync() {
        streaming = false
        store.syncEnabled = false
        senderThread = nil
        setState(devices.isEmpty ? .idle : .paired)
    }

    // MARK: - UDP frame

    private static func sendFrame(fd: Int32, target: StreamTarget, r: UInt8, g: UInt8, b: UInt8) {
        let count = target.panelIds.count
        let size = 2 + count * 8
        var buf = Data(count: size)
        buf[0] = UInt8((count >> 8) & 0xFF)
        buf[1] = UInt8(count & 0xFF)
        for (i, panelId) in target.panelIds.enumerated() {
            let off = 2 + i * 8
            buf[off] = UInt8((panelId >> 8) & 0xFF)
            buf[off + 1] = UInt8(panelId & 0xFF)
            buf[off + 2] = r
            buf[off + 3] = g
            buf[off + 4] = b
            buf[off + 5] = 0 // W
            buf[off + 6] = 0 // transition high byte
            buf[off + 7] = 1 // transition = 1 (100ms)
        }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(target.udpPort).bigEndian
        addr.sin_addr.s_addr = inet_addr(target.creds.ip)
        buf.withUnsafeBytes { ptr in
            withUnsafePointer(to: &addr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    _ = sendto(fd, ptr.baseAddress, size, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    // MARK: - Color

    private static let audioHueBass: Float = 280
    private static let audioHueTreble: Float = 190
    private static let satAudio: Float = 0.9
    private static let flashDecay: Float = 0.85

    private static func hsvToRgb(h: Float, s: Float, v: Float) -> (r: UInt8, g: UInt8, b: UInt8) {
        let hh = ((h.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360) / 60
        let i = Int(hh)
        let f = hh - Float(i)
        let p = v * (1 - s)
        let q = v * (1 - s * f)
        let t = v * (1 - s * (1 - f))
        let (rf, gf, bf): (Float, Float, Float)
        switch i {
        case 0: (rf, gf, bf) = (v, t, p)
        case 1: (rf, gf, bf) = (q, v, p)
        case 2: (rf, gf, bf) = (p, v, t)
        case 3: (rf, gf, bf) = (p, q, v)
        case 4: (rf, gf, bf) = (t, p, v)
        default: (rf, gf, bf) = (v, p, q)
        }
        return (UInt8(rf * 255), UInt8(gf * 255), UInt8(bf * 255))
    }

    // MARK: - State

    private func setState(_ s: State) {
        state = s
        let cb = onStateChange
        DispatchQueue.main.async { cb?(s) }
    }
}

// MARK: - Discovery types

private struct DiscoveredDevice {
    let id: String
    let ip: String
    let port: Int
    let name: String
}

// MARK: - mDNS delegate

private class BrowserDelegate: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    weak var controller: NanoleafController?
    private var resolving: [NetService] = []

    init(controller: NanoleafController) {
        self.controller = controller
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        resolving.append(service)
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let controller,
              sender.hostName != nil,
              let ip = resolveIP(sender)
        else { return }

        let id = deviceId(from: sender) ?? sender.name
        let port = sender.port > 0 ? sender.port : NanoleafApi.defaultPort

        let device = DiscoveredDevice(id: id, ip: ip, port: port, name: sender.name)
        controller.lock.lock()
        controller.discovered[id] = device
        controller.lock.unlock()
    }

    private func deviceId(from service: NetService) -> String? {
        guard let txt = service.txtRecordData() else { return nil }
        let dict = NetService.dictionary(fromTXTRecord: txt)
        if let idData = dict["id"], let id = String(data: idData, encoding: .utf8), !id.isEmpty {
            return id
        }
        return nil
    }

    private func resolveIP(_ service: NetService) -> String? {
        guard let addresses = service.addresses else { return nil }
        for addr in addresses {
            if addr.count == MemoryLayout<sockaddr_in>.size {
                let ip = addr.withUnsafeBytes { ptr -> String? in
                    let sa = ptr.load(as: sockaddr_in.self)
                    guard sa.sin_family == sa_family_t(AF_INET) else { return nil }
                    var inAddr = sa.sin_addr
                    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    inet_ntop(AF_INET, &inAddr, &buf, socklen_t(INET_ADDRSTRLEN))
                    if let end = buf.firstIndex(of: 0) {
                        return String(decoding: buf[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    }
                    return String(decoding: buf.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                }
                if let ip { return ip }
            }
        }
        return service.hostName?.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
}

private extension Float {
    func clamped(_ lo: Float, _ hi: Float) -> Float {
        Swift.min(Swift.max(self, lo), hi)
    }
}
