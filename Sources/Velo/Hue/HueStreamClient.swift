import Foundation
import Network

/// Low-latency Hue Entertainment stream client.
///
/// Opens a DTLS-PSK session to the bridge on UDP port 2100 and streams
/// Hue Entertainment v2.0 binary frames. Frames are fire-and-forget UDP —
/// no ACK, no blocking — which keeps light latency in the single-digit ms range.
///
/// Uses Network.framework's native DTLS support with PSK authentication.
final class HueStreamClient: @unchecked Sendable {

    private let bridgeIp: String
    private let identity: Data
    private let psk: Data
    private let areaId: String

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.velo.hue.stream")
    private var sequence: UInt8 = 0

    private(set) var packetsSent: Int64 = 0
    private(set) var packetsFailed: Int64 = 0

    private let header: Data
    private let maxChannels = 20
    private let bytesPerChannel = 7

    init(bridgeIp: String, username: String, clientKey: String, areaId: String) {
        self.bridgeIp = bridgeIp
        self.identity = Data(username.utf8)
        self.psk = Self.hexToBytes(clientKey)
        self.areaId = areaId
        self.header = Self.buildHeader(areaId: areaId)
    }

    /// Establish the DTLS-PSK session. Calls `completion` on the internal queue.
    func connect(completion: @escaping @Sendable (Error?) -> Void) {
        let tlsOptions = NWProtocolTLS.Options()

        // sig: (options, psk_key, psk_identity)
        sec_protocol_options_add_pre_shared_key(
            tlsOptions.securityProtocolOptions,
            psk.withUnsafeBytes { DispatchData(bytes: $0) as __DispatchData },
            identity.withUnsafeBytes { DispatchData(bytes: $0) as __DispatchData }
        )

        // TLS_PSK_WITH_AES_128_GCM_SHA256 = 0x00A8 (IANA).
        if let suite = tls_ciphersuite_t(rawValue: 0x00A8) {
            sec_protocol_options_append_tls_ciphersuite(
                tlsOptions.securityProtocolOptions, suite)
        }

        let params = NWParameters(dtls: tlsOptions, udp: .init())

        guard let port = NWEndpoint.Port(rawValue: 2100) else {
            completion(HueStreamError.invalidPort)
            return
        }
        let endpoint = NWEndpoint.hostPort(host: .init(bridgeIp), port: port)
        let conn = NWConnection(to: endpoint, using: params)

        let once = Once()
        let finish: @Sendable (Error?) -> Void = { error in
            guard once.claim() else { return }
            completion(error)
        }

        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                VeloLog.write("hue", "DTLS stream connected to \(self?.bridgeIp ?? "?"):2100")
                finish(nil)
            case .failed(let error):
                VeloLog.write("hue", "DTLS connection failed: \(error)")
                finish(error)
            case .waiting(let error):
                VeloLog.write("hue", "DTLS waiting: \(error)")
            case .cancelled:
                VeloLog.write("hue", "DTLS connection cancelled")
                finish(HueStreamError.connectionFailed("Connection cancelled"))
            default:
                break
            }
        }

        self.connection = conn
        conn.start(queue: queue)

        queue.asyncAfter(deadline: .now() + 8) {
            finish(HueStreamError.connectionFailed("DTLS handshake timed out"))
        }
    }

    /// Send one frame. `channelIds` and `rgb` are parallel; rgb is interleaved
    /// r,g,b in 0..1, length = channelIds.count * 3.
    func send(channelIds: [Int], rgb: [Float]) {
        guard let conn = connection else { return }
        let n = min(channelIds.count, maxChannels)

        var frame = Data(capacity: header.count + n * bytesPerChannel)
        frame.append(header)
        frame[header.count - header.count + 11] = sequence
        sequence &+= 1

        for i in 0..<n {
            frame.append(UInt8(channelIds[i] & 0xFF))
            appendColor16(&frame, rgb[i * 3])
            appendColor16(&frame, rgb[i * 3 + 1])
            appendColor16(&frame, rgb[i * 3 + 2])
        }

        conn.send(content: frame, completion: .contentProcessed { [weak self] error in
            if error != nil {
                self?.packetsFailed += 1
            } else {
                self?.packetsSent += 1
            }
        })
    }

    func close() {
        connection?.cancel()
        connection = nil
    }

    private func appendColor16(_ data: inout Data, _ value: Float) {
        let v = UInt16(min(max(value, 0), 1) * 65535)
        data.append(UInt8(v >> 8))
        data.append(UInt8(v & 0xFF))
    }

    private static func buildHeader(areaId: String) -> Data {
        var h = Data()
        h.append(contentsOf: "HueStream".utf8)     // 9 bytes
        h.append(0x02)                               // version major
        h.append(0x00)                               // version minor
        h.append(0x00)                               // sequence (overwritten per frame)
        h.append(0x00)                               // reserved
        h.append(0x00)                               // reserved
        h.append(0x00)                               // color space: 0 = RGB
        h.append(0x00)                               // reserved
        h.append(contentsOf: areaId.utf8)            // 36-char UUID
        return h
    }

    static func hexToBytes(_ hex: String) -> Data {
        let clean = hex.trimmingCharacters(in: .whitespaces)
        var data = Data(capacity: clean.count / 2)
        var i = clean.startIndex
        while i < clean.endIndex {
            let next = clean.index(i, offsetBy: 2)
            if let byte = UInt8(clean[i..<next], radix: 16) {
                data.append(byte)
            }
            i = next
        }
        return data
    }
}

enum HueStreamError: Error, LocalizedError {
    case invalidPort
    case connectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidPort: "Invalid port."
        case .connectionFailed(let msg): msg
        }
    }
}

/// Thread-safe single-fire gate.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !fired else { return false }
        fired = true
        return true
    }
}
