import Foundation

/// UserDefaults-backed persistence for discovered LIFX bulbs and their selection state.
final class LifxStore: @unchecked Sendable {

    private let defaults = UserDefaults.standard
    private let key = "lifx_cached_bulbs"

    func save(_ bulbs: [LifxBulb]) {
        let arr = bulbs.map { b -> [String: Any] in
            [
                "ip": b.ip,
                "mac": b.mac.base64EncodedString(),
                "label": b.label,
                "selected": b.isSelected,
            ]
        }
        defaults.set(arr, forKey: key)
    }

    func load() -> [LifxBulb] {
        guard let arr = defaults.array(forKey: key) as? [[String: Any]] else { return [] }
        return arr.compactMap { dict in
            guard let ip = dict["ip"] as? String,
                  let macB64 = dict["mac"] as? String,
                  let mac = Data(base64Encoded: macB64),
                  let label = dict["label"] as? String else { return nil }
            let selected = dict["selected"] as? Bool ?? false
            return LifxBulb(ip: ip, mac: mac, label: label, isSelected: selected)
        }
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}
