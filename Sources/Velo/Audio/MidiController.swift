import CoreMIDI
import Foundation

/// Listens to all connected MIDI sources and dispatches mapped actions.
///
/// The initial mapping is simple: any CC or note triggers a "next" or "previous"
/// visual action. The user assigns which CC/note does what via MIDI learn in
/// the settings panel.
final class MidiController: @unchecked Sendable {

    enum Action: Codable, Equatable {
        case previousVisual
        case nextVisual
    }

    struct Mapping: Codable, Equatable {
        var previousVisual: MidiTrigger?
        var nextVisual: MidiTrigger?
    }

    struct MidiTrigger: Codable, Equatable {
        enum Kind: String, Codable { case cc, note }
        var kind: Kind
        var channel: UInt8
        var number: UInt8
    }

    var mapping: Mapping {
        didSet { saveMappings() }
    }

    var onAction: ((Action) -> Void)?

    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var connectedSources: Set<MIDIEndpointRef> = []

    /// When non-nil, the next incoming CC or note-on is captured as a mapping
    /// for this action, then learn mode is cleared.
    var learnTarget: Action? {
        get { lock.lock(); defer { lock.unlock() }; return _learnTarget }
        set { lock.lock(); _learnTarget = newValue; lock.unlock() }
    }
    private var _learnTarget: Action?
    private let lock = NSLock()

    init() {
        mapping = Self.loadMappings()
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
        var packet = eventList.packet
        for _ in 0..<eventList.numPackets {
            let words = Mirror(reflecting: packet.words).children.map { $0.value as! UInt32 }
            for word in words where word != 0 {
                let status = UInt8((word >> 16) & 0xF0)
                let channel = UInt8((word >> 16) & 0x0F)
                let data1 = UInt8((word >> 8) & 0xFF)
                let data2 = UInt8(word & 0xFF)

                if status == 0xB0 && data2 > 0 {
                    handleTrigger(MidiTrigger(kind: .cc, channel: channel, number: data1))
                } else if status == 0x90 && data2 > 0 {
                    handleTrigger(MidiTrigger(kind: .note, channel: channel, number: data1))
                }
            }
            var current = packet
            withUnsafePointer(to: &current) {
                $0.withMemoryRebound(to: MIDIEventPacket.self, capacity: 1) { p in
                    packet = MIDIEventPacketNext(p).pointee
                }
            }
        }
    }

    private func handleTrigger(_ trigger: MidiTrigger) {
        lock.lock()
        let learn = _learnTarget
        lock.unlock()

        if let learn {
            DispatchQueue.main.async { [self] in
                switch learn {
                case .previousVisual: mapping.previousVisual = trigger
                case .nextVisual: mapping.nextVisual = trigger
                }
                learnTarget = nil
            }
            return
        }

        let action: Action?
        if trigger == mapping.previousVisual {
            action = .previousVisual
        } else if trigger == mapping.nextVisual {
            action = .nextVisual
        } else {
            action = nil
        }

        if let action {
            DispatchQueue.main.async { [self] in
                onAction?(action)
            }
        }
    }

    // MARK: - Persistence

    private static let key = "velo_midi_mapping"

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
}

extension MidiController.MidiTrigger {
    var displayName: String {
        let type = kind == .cc ? "CC" : "Note"
        return "\(type) \(number) ch\(channel + 1)"
    }
}
