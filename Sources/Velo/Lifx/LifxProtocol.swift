import Foundation

/// LIFX LAN protocol packet builder. All packets are little-endian UDP on port 56700.
/// Reference: https://lan.developer.lifx.com/docs/packet-contents
enum LifxProtocol {

    static let port: UInt16 = 56700
    static let source: UInt32 = 12345

    // MARK: - Discovery

    /// GetLabel (type 23), broadcast, tagged. 36-byte header, no payload.
    static func discoveryPacket() -> Data {
        var buf = Data(count: 36)
        buf.writeLE16(0, 36)                 // size
        buf.writeLE16(2, 0x3400)             // protocol 1024 + addressable + tagged
        buf.writeLE32(4, source)             // source
        // target (8 bytes) = 0 for broadcast — already zeroed
        // reserved (6), ack/res (1), sequence (1) — zeroed
        // reserved (8) — zeroed
        buf.writeLE16(32, 23)                // type: GetLabel
        // reserved (2) — zeroed
        return buf
    }

    // MARK: - SetPower (type 117) — 42 bytes

    static func setPower(mac: Data, on: Bool) -> Data {
        var buf = Data(count: 42)
        writeHeader(&buf, size: 42, mac: mac, type: 117)
        buf.writeLE16(36, on ? 65535 : 0)    // level
        // duration (4) — zeroed = instant
        return buf
    }

    // MARK: - SetColor (type 102) — 49 bytes

    /// `hue` in 0..360, `sat`/`bri` in 0..1, `kelvin` typically 2500..9000.
    static func setColor(mac: Data, hue: Float, sat: Float, bri: Float, kelvin: UInt16 = 3500, durationMs: UInt32 = 0) -> Data {
        var buf = Data(count: 49)
        writeHeader(&buf, size: 49, mac: mac, type: 102)
        // payload byte 0: reserved — zeroed
        let h16 = UInt16((hue / 360.0) * 65535.0)
        let s16 = UInt16(sat * 65535.0)
        let b16 = UInt16(bri * 65535.0)
        buf.writeLE16(37, h16)
        buf.writeLE16(39, s16)
        buf.writeLE16(41, b16)
        buf.writeLE16(43, kelvin)
        buf.writeLE32(45, durationMs)
        return buf
    }

    // MARK: - Response parsing

    struct LabelResponse {
        let mac: Data    // 8 bytes
        let label: String
    }

    /// Parse a StateLabel (type 25) response. Returns nil if the packet is not a StateLabel.
    static func parseLabelResponse(_ data: Data) -> LabelResponse? {
        guard data.count >= 36 + 32 else { return nil }
        let type = data.readLE16(32)
        guard type == 25 else { return nil }
        let mac = data.subdata(in: 8..<16)
        let labelBytes = data.subdata(in: 36..<68)
        let label = String(data: labelBytes, encoding: .utf8)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            .trimmingCharacters(in: .whitespaces)
        return LabelResponse(mac: mac, label: label?.isEmpty == false ? label! : "LIFX Bulb")
    }

    // MARK: - Header

    private static func writeHeader(_ buf: inout Data, size: UInt16, mac: Data, type: UInt16) {
        buf.writeLE16(0, size)
        buf.writeLE16(2, 0x1400)             // addressable, protocol 1024 (not tagged)
        buf.writeLE32(4, source)
        buf.replaceSubrange(8..<16, with: mac.prefix(8))
        // reserved (6), ack/res (1), sequence (1) — zeroed
        // reserved (8) — zeroed
        buf.writeLE16(32, type)
        // reserved (2) — zeroed
    }
}

// MARK: - Data helpers for little-endian writes/reads

private extension Data {
    mutating func writeLE16(_ offset: Int, _ value: UInt16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { self.replaceSubrange(offset..<offset+2, with: $0) }
    }
    mutating func writeLE32(_ offset: Int, _ value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { self.replaceSubrange(offset..<offset+4, with: $0) }
    }
    func readLE16(_ offset: Int) -> UInt16 {
        self.subdata(in: offset..<offset+2).withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
    }
}
