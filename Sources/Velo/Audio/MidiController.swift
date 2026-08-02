import CoreMIDI
import Foundation

/// Listens to all connected MIDI sources and dispatches mapped actions.
///
/// A mapping binds one CC or note to one action: step the visual forward or
/// back, or recall one of the ten favourite slots (the same slots the 1–9/0
/// number keys reach). The user assigns each one via MIDI learn in the
/// settings panel.
///
/// `enabled` is the master switch. When off, incoming MIDI is ignored entirely
/// and the mappings are left untouched, so turning it back on restores the
/// controller exactly as it was.
@Observable
final class MidiController: @unchecked Sendable {

    /// Number of favourite-recall slots, matching the 1–9/0 number-key row.
    static let favouriteSlots = 10

    enum Action: Codable, Equatable, Hashable {
        case previousVisual
        case nextVisual
        /// Recall favourite slot `index` (0-based; slot 0 is the "1" key).
        case favourite(Int)
    }

    struct Mapping: Codable, Equatable {
        var previousVisual: MidiTrigger?
        var nextVisual: MidiTrigger?
        /// One trigger per favourite slot; always `favouriteSlots` long.
        var favourites: [MidiTrigger?]

        init(previousVisual: MidiTrigger? = nil,
             nextVisual: MidiTrigger? = nil,
             favourites: [MidiTrigger?] = []) {
            self.previousVisual = previousVisual
            self.nextVisual = nextVisual
            self.favourites = Self.padded(favourites)
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            previousVisual = try c.decodeIfPresent(MidiTrigger.self, forKey: .previousVisual)
            nextVisual = try c.decodeIfPresent(MidiTrigger.self, forKey: .nextVisual)
            // Mappings saved before the favourite slots existed have no such key.
            let saved = try c.decodeIfPresent([MidiTrigger?].self, forKey: .favourites) ?? []
            favourites = Self.padded(saved)
        }

        /// Trim or pad so the array is always exactly `favouriteSlots` long —
        /// the UI and the subscript both index it directly.
        private static func padded(_ list: [MidiTrigger?]) -> [MidiTrigger?] {
            var out = Array(list.prefix(favouriteSlots))
            out.append(contentsOf:
                repeatElement(nil, count: favouriteSlots - out.count))
            return out
        }

        subscript(action: Action) -> MidiTrigger? {
            get {
                switch action {
                case .previousVisual: return previousVisual
                case .nextVisual: return nextVisual
                case .favourite(let i):
                    return favourites.indices.contains(i) ? favourites[i] : nil
                }
            }
            set {
                switch action {
                case .previousVisual: previousVisual = newValue
                case .nextVisual: nextVisual = newValue
                case .favourite(let i):
                    guard favourites.indices.contains(i) else { return }
                    favourites[i] = newValue
                }
            }
        }

        /// The action bound to `trigger`, if any.
        func action(for trigger: MidiTrigger) -> Action? {
            if trigger == previousVisual { return .previousVisual }
            if trigger == nextVisual { return .nextVisual }
            if let i = favourites.firstIndex(of: trigger) { return .favourite(i) }
            return nil
        }

        /// Remove every binding for `trigger`.
        mutating func unbind(_ trigger: MidiTrigger) {
            if previousVisual == trigger { previousVisual = nil }
            if nextVisual == trigger { nextVisual = nil }
            for i in favourites.indices where favourites[i] == trigger {
                favourites[i] = nil
            }
        }
    }

    struct MidiTrigger: Codable, Equatable {
        enum Kind: String, Codable { case cc, note }
        var kind: Kind
        var channel: UInt8
        var number: UInt8
    }

    /// Master switch. Off ignores all incoming MIDI without clearing mappings.
    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            if !enabled { learnTarget = nil }
        }
    }

    var mapping: Mapping {
        didSet { saveMappings() }
    }

    var channelFilter: UInt8? {
        didSet { saveChannelFilter() }
    }

    @ObservationIgnored var onAction: ((Action) -> Void)?

    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var connectedSources: Set<MIDIEndpointRef> = []

    /// When non-nil, the next incoming CC or note-on is captured as a mapping
    /// for this action, then learn mode is cleared.
    var learnTarget: Action?

    init() {
        enabled = Self.loadEnabled()
        mapping = Self.loadMappings()
        channelFilter = Self.loadChannelFilter()
        setupMidi()
    }

    private func setupMidi() {
        let status = MIDIClientCreateWithBlock("Velo MIDI" as CFString, &client) { [weak self] notification in
            if notification.pointee.messageID == .msgSetupChanged {
                DispatchQueue.main.async { self?.reconnectSources() }
            }
        }
        guard status == noErr else { return }

        MIDIInputPortCreateWithProtocol(
            client, "Velo Input" as CFString, ._1_0, &inputPort
        ) { [weak self] eventList, _ in
            self?.handleMidiPackets(eventList)
        }

        reconnectSources()
    }

    private func reconnectSources() {
        let sourceCount = MIDIGetNumberOfSources()
        var current: Set<MIDIEndpointRef> = []
        for i in 0..<sourceCount {
            let src = MIDIGetSource(i)
            current.insert(src)
            if !connectedSources.contains(src) {
                MIDIPortConnectSource(inputPort, src, nil)
            }
        }
        for old in connectedSources where !current.contains(old) {
            MIDIPortDisconnectSource(inputPort, old)
        }
        connectedSources = current
    }

    private func handleMidiPackets(_ eventListPtr: UnsafePointer<MIDIEventList>) {
        let eventList = eventListPtr.pointee
        var packetPtr = UnsafeRawPointer(eventListPtr)
            .advanced(by: MemoryLayout.offset(of: \MIDIEventList.packet)!)
            .assumingMemoryBound(to: MIDIEventPacket.self)

        for _ in 0..<eventList.numPackets {
            let packet = packetPtr.pointee
            let wordCount = Int(packet.wordCount)
            let wordsPtr = UnsafeRawPointer(packetPtr)
                .advanced(by: MemoryLayout.offset(of: \MIDIEventPacket.words)!)
                .assumingMemoryBound(to: UInt32.self)

            for i in 0..<wordCount {
                let word = wordsPtr[i]
                if word == 0 { continue }

                let status = UInt8((word >> 16) & 0xF0)
                let channel = UInt8((word >> 16) & 0x0F)
                let data1 = UInt8((word >> 8) & 0xFF)
                let data2 = UInt8(word & 0xFF)

                if let filter = channelFilter, channel != filter {
                    continue
                }

                if status == 0xB0 && data2 > 0 {
                    handleTrigger(MidiTrigger(kind: .cc, channel: channel, number: data1))
                } else if status == 0x90 && data2 > 0 {
                    handleTrigger(MidiTrigger(kind: .note, channel: channel, number: data1))
                }
            }
            packetPtr = UnsafePointer(MIDIEventPacketNext(packetPtr))
        }
    }

    private func handleTrigger(_ trigger: MidiTrigger) {
        DispatchQueue.main.async { [self] in
            guard enabled else { return }

            if let learn = learnTarget {
                // One mutation, so the mapping is only saved once. Learning
                // moves the control rather than copying it, so a single CC can
                // never drive two actions at once.
                var next = mapping
                next.unbind(trigger)
                next[learn] = trigger
                mapping = next
                learnTarget = nil
                return
            }

            if let action = mapping.action(for: trigger) {
                onAction?(action)
            }
        }
    }

    // MARK: - Persistence

    private static let key = "velo_midi_mapping"
    private static let channelKey = "velo_midi_channel_filter"
    private static let enabledKey = "velo_midi_enabled"

    /// Defaults on, so existing mappings keep working after an update.
    private static func loadEnabled() -> Bool {
        guard UserDefaults.standard.object(forKey: enabledKey) != nil else { return true }
        return UserDefaults.standard.bool(forKey: enabledKey)
    }

    private static func loadMappings() -> Mapping {
        guard let data = UserDefaults.standard.data(forKey: key),
              let m = try? JSONDecoder().decode(Mapping.self, from: data)
        else { return Mapping() }
        return m
    }

    private func saveMappings() {
        guard let data = try? JSONEncoder().encode(mapping) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    private static func loadChannelFilter() -> UInt8? {
        let val = UserDefaults.standard.integer(forKey: channelKey)
        // integer(forKey:) returns 0 if missing. We can encode nil as 0xFF, or just
        // check object(forKey:).
        guard UserDefaults.standard.object(forKey: channelKey) != nil else { return nil }
        return val == 255 ? nil : UInt8(val)
    }

    private func saveChannelFilter() {
        if let f = channelFilter {
            UserDefaults.standard.set(Int(f), forKey: Self.channelKey)
        } else {
            UserDefaults.standard.set(255, forKey: Self.channelKey)
        }
    }
}

extension MidiController.MidiTrigger {
    var displayName: String {
        let type = kind == .cc ? "CC" : "Note"
        return "\(type) \(number) ch\(channel + 1)"
    }
}
