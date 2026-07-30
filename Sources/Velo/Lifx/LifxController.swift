import Foundation
import Network

/// LIFX LAN controller: discovery via UDP broadcast, per-bulb selection,
/// ~50 Hz audio-reactive sender thread using LightingSettings, and static
/// color/power control. Matches Android's LifxController feature-for-feature.
final class LifxController: @unchecked Sendable {

    let store = LifxStore()

    private var bulbs: [LifxBulb] = []
    private let lock = NSLock()

    private var streaming = false
    private var senderThread: Thread?

    var isStreaming: Bool { streaming }

    init() {
        bulbs = store.load()
    }

    // MARK: - Bulb list

    func cachedBulbs() -> [LifxBulb] {
        lock.lock(); defer { lock.unlock() }
        return bulbs
    }

    func hasSelectedBulbs() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return bulbs.contains(where: \.isSelected)
    }

    func setBulbSelected(ip: String, selected: Bool) {
        lock.lock()
        guard let idx = bulbs.firstIndex(where: { $0.ip == ip }) else { lock.unlock(); return }
        bulbs[idx].isSelected = selected
        store.save(bulbs)
        let bulb = bulbs[idx]
        lock.unlock()

        if streaming {
            DispatchQueue.global(qos: .userInitiated).async {
                Self.sendPower(ip: bulb.ip, mac: bulb.mac, on: selected)
            }
        }
    }

    func forgetBulbs() {
        lock.lock()
        bulbs.removeAll()
        store.clear()
        lock.unlock()
    }

    // MARK: - Discovery

    func startDiscovery(onBulbFound: @escaping @Sendable (LifxBulb) -> Void,
                        onFinished: @escaping @Sendable () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { onFinished(); return }
            do {
                let socket = try Self.udpSocket()
                defer { socket.close() }
                let packet = LifxProtocol.discoveryPacket()
                let broadcast = Self.broadcastAddress()

                for _ in 0..<4 {
                    try? socket.send(packet, to: broadcast)
                    let deadline = Date().addingTimeInterval(1.0)
                    while Date() < deadline {
                        let remaining = deadline.timeIntervalSinceNow
                        guard remaining > 0 else { break }
                        guard let (data, sender) = try? socket.receive(timeout: remaining) else { break }
                        if let resp = LifxProtocol.parseLabelResponse(data) {
                            let ip = sender
                            let bulb = LifxBulb(ip: ip, mac: resp.mac, label: resp.label)
                            self.lock.lock()
                            if let existing = self.bulbs.firstIndex(where: { $0.mac == bulb.mac }) {
                                let old = self.bulbs[existing]
                                if old.ip != ip || old.label != bulb.label {
                                    let updated = LifxBulb(ip: ip, mac: resp.mac, label: resp.label, isSelected: old.isSelected)
                                    self.bulbs[existing] = updated
                                    self.store.save(self.bulbs)
                                    self.lock.unlock()
                                    onBulbFound(updated)
                                } else {
                                    self.lock.unlock()
                                }
                            } else {
                                self.bulbs.append(bulb)
                                self.store.save(self.bulbs)
                                self.lock.unlock()
                                onBulbFound(bulb)
                            }
                        }
                    }
                }
            } catch {
                VeloLog.write("lifx", "Discovery error: \(error.localizedDescription)")
            }
            onFinished()
        }
    }

    // MARK: - Static control (not streaming — direct scene/power commands)

    func setStaticPower(on: Bool) {
        let targets = selectedBulbs()
        DispatchQueue.global(qos: .userInitiated).async {
            for b in targets {
                Self.sendPower(ip: b.ip, mac: b.mac, on: on)
            }
        }
    }

    func setStaticColor(hue: Float? = nil, sat: Float? = nil, brightness: Float? = nil, kelvin: Int = 3500) {
        let targets = selectedBulbs()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let socket = try Self.udpSocket()
                defer { socket.close() }
                for b in targets {
                    let packet = LifxProtocol.setColor(
                        mac: b.mac,
                        hue: hue ?? 0,
                        sat: sat ?? 0,
                        bri: brightness ?? 1.0,
                        kelvin: UInt16(kelvin),
                        durationMs: 400
                    )
                    try? socket.send(packet, toIP: b.ip)
                }
            } catch {}
        }
    }

    // MARK: - Streaming

    func enableStreaming() {
        guard !streaming else { return }
        streaming = true
        startSender()
    }

    func disableStreaming() {
        streaming = false
        senderThread = nil

        let targets = selectedBulbs()
        DispatchQueue.global(qos: .userInitiated).async {
            for b in targets {
                Self.sendPower(ip: b.ip, mac: b.mac, on: false)
            }
        }
    }

    private func selectedBulbs() -> [LifxBulb] {
        lock.lock(); defer { lock.unlock() }
        return bulbs.filter(\.isSelected)
    }

    // MARK: - Sender thread

    private func startSender() {
        let thread = Thread { [weak self] in
            guard let self else { return }

            let cfg = LightingSettings.shared
            var flash: Float = 0
            var lastBeat = BeatBus.shared.beatCount
            var lastBeatNs: UInt64 = 0
            var smoothedBri: Float = cfg.restingGlow
            let frameNs: UInt64 = 1_000_000_000 / 50

            guard let socket = try? Self.udpSocket() else {
                VeloLog.write("lifx", "Failed to create sender socket")
                self.streaming = false
                return
            }
            defer { socket.close() }

            // Power on all selected bulbs at start
            let startTargets = self.selectedBulbs()
            for b in startTargets {
                Self.sendPower(ip: b.ip, mac: b.mac, on: true)
            }

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

                let color = Self.calculateAudioColor(cfg: cfg, bus: bus, flash: flash, smoothedBri: &smoothedBri)
                let active = self.selectedBulbs()
                let count = active.count

                for (i, bulb) in active.enumerated() {
                    let spread: Float = count > 1
                        ? (Float(i) / Float(count - 1) - 0.5) * Self.audioChannelSpread
                        : 0
                    let bulbHue = (color.hue + spread * 360).clamped(0, 360)
                    let packet = LifxProtocol.setColor(
                        mac: bulb.mac,
                        hue: bulbHue,
                        sat: color.sat,
                        bri: color.bri,
                        durationMs: 0
                    )
                    try? socket.send(packet, toIP: bulb.ip)
                }

                let elapsed = DispatchTime.now().uptimeNanoseconds - t0
                if elapsed < frameNs {
                    Thread.sleep(forTimeInterval: Double(frameNs - elapsed) / 1_000_000_000)
                }
            }
        }
        thread.name = "lifx-sender"
        thread.qualityOfService = .userInteractive
        senderThread = thread
        thread.start()
    }

    // MARK: - Color calculation (matches Android + Hue)

    private struct LifxColor {
        let hue: Float
        let sat: Float
        let bri: Float
    }

    private static func calculateAudioColor(cfg: LightingSettings, bus: BeatBus, flash: Float, smoothedBri: inout Float) -> LifxColor {
        let low = bus.bassRatio
        let mid: Float = 0.5
        let high: Float = 1.0 - low

        let total = low + mid + high + 1e-3
        let centroid = ((mid * 0.5 + high) / total).clamped(0, 1)
        let rawBri = cfg.audioBrightnessValue(low: low, mid: mid, high: high, flash: flash)
        smoothedBri += (rawBri - smoothedBri) * cfg.brightnessSmoothing
        let bri = smoothedBri
        let sat = max(0.6, audioSat - flash * 0.3)
        let hue = audioHueBass + (audioHueTreble - audioHueBass) * centroid
        return LifxColor(hue: hue, sat: sat, bri: bri)
    }

    // MARK: - UDP helpers

    private static func sendPower(ip: String, mac: Data, on: Bool) {
        guard let socket = try? udpSocket() else { return }
        defer { socket.close() }
        let packet = LifxProtocol.setPower(mac: mac, on: on)
        try? socket.send(packet, toIP: ip)
    }

    private static func udpSocket() throws -> LifxSocket {
        try LifxSocket()
    }

    private static func broadcastAddress() -> String {
        "255.255.255.255"
    }

    // MARK: - Constants

    private static let flashDecay: Float = 0.80
    private static let audioSat: Float = 0.92
    private static let audioHueBass: Float = 360
    private static let audioHueTreble: Float = 220
    private static let audioChannelSpread: Float = 0.22
}

// MARK: - LifxBulb

struct LifxBulb: Identifiable, Sendable {
    let ip: String
    let mac: Data
    let label: String
    var isSelected: Bool

    var id: Data { mac }

    init(ip: String, mac: Data, label: String, isSelected: Bool = false) {
        self.ip = ip
        self.mac = mac
        self.label = label
        self.isSelected = isSelected
    }
}

// MARK: - BSD socket wrapper for UDP

final class LifxSocket: @unchecked Sendable {
    private let fd: Int32

    init() throws {
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw LifxError.socketFailed }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    func send(_ data: Data, to broadcastIP: String) throws {
        try send(data, toIP: broadcastIP)
    }

    func send(_ data: Data, toIP ip: String) throws {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(LifxProtocol.port).bigEndian
        addr.sin_addr.s_addr = inet_addr(ip)
        let sent = data.withUnsafeBytes { ptr in
            withUnsafePointer(to: &addr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.sendto(fd, ptr.baseAddress, data.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if sent < 0 { throw LifxError.sendFailed }
    }

    /// Receive with a timeout. Returns (data, senderIP) or nil on timeout.
    func receive(timeout: TimeInterval) throws -> (Data, String)? {
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout.truncatingRemainder(dividingBy: 1)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var buf = [UInt8](repeating: 0, count: 128)
        var addr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = withUnsafeMutablePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                recvfrom(fd, &buf, buf.count, 0, sa, &addrLen)
            }
        }
        if n <= 0 { return nil }

        var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var inAddr = addr.sin_addr
        inet_ntop(AF_INET, &inAddr, &ipBuf, socklen_t(INET_ADDRSTRLEN))
        let ip: String = {
            if let end = ipBuf.firstIndex(of: 0) {
                return String(decoding: ipBuf[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
            return String(decoding: ipBuf.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }()
        return (Data(buf.prefix(n)), ip)
    }

    func close() {
        Darwin.close(fd)
    }

    deinit { Darwin.close(fd) }
}

enum LifxError: Error {
    case socketFailed
    case sendFailed
}

private extension Float {
    func clamped(_ lo: Float, _ hi: Float) -> Float {
        Swift.min(Swift.max(self, lo), hi)
    }
}
