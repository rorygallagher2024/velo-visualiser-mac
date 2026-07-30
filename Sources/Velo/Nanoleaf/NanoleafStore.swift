import Foundation

/// Persisted credentials for a single paired Nanoleaf device.
struct NanoleafCredentials: Codable, Identifiable, Sendable {
    var ip: String
    let token: String
    let port: Int
    let deviceId: String
    var name: String
    var syncOn: Bool

    var id: String { deviceId }
}

/// UserDefaults-backed persistence for paired Nanoleaf devices.
final class NanoleafStore: @unchecked Sendable {

    private let defaults = UserDefaults.standard
    private static let key = "nanoleaf_devices"
    private static let syncKey = "nanoleaf_sync_enabled"

    func loadAll() -> [NanoleafCredentials] {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        return (try? JSONDecoder().decode([NanoleafCredentials].self, from: data)) ?? []
    }

    func save(_ devices: [NanoleafCredentials]) {
        if let data = try? JSONEncoder().encode(devices) {
            defaults.set(data, forKey: Self.key)
        }
    }

    func upsert(_ creds: NanoleafCredentials) {
        var all = loadAll()
        if let idx = all.firstIndex(where: { $0.deviceId == creds.deviceId }) {
            all[idx] = creds
        } else {
            all.append(creds)
        }
        save(all)
    }

    func remove(deviceId: String) {
        var all = loadAll()
        all.removeAll(where: { $0.deviceId == deviceId })
        save(all)
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
        defaults.removeObject(forKey: Self.syncKey)
    }

    var syncEnabled: Bool {
        get { defaults.bool(forKey: Self.syncKey) }
        set { defaults.set(newValue, forKey: Self.syncKey) }
    }
}
