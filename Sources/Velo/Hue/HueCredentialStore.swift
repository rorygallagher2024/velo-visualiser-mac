import Foundation

/// UserDefaults-backed persistence for Hue pairing credentials and the
/// selected area. These are LAN-only bridge credentials (username + clientkey)
/// — same approach as Android's SharedPreferences.
final class HueCredentialStore: @unchecked Sendable {

    private let defaults = UserDefaults.standard
    private let prefix = "hue_"

    func save(_ creds: HueCredentials) {
        defaults.set(creds.bridgeIp, forKey: key("bridge_ip"))
        defaults.set(creds.username, forKey: key("username"))
        defaults.set(creds.clientKey, forKey: key("clientkey"))
    }

    func load() -> HueCredentials? {
        guard let ip = defaults.string(forKey: key("bridge_ip")),
              let user = defaults.string(forKey: key("username")),
              let ck = defaults.string(forKey: key("clientkey")) else { return nil }
        return HueCredentials(bridgeIp: ip, username: user, clientKey: ck)
    }

    var selectedAreaId: String? {
        get { defaults.string(forKey: key("area_id")) }
        set { defaults.set(newValue, forKey: key("area_id")) }
    }

    var syncEnabled: Bool {
        get { defaults.bool(forKey: key("sync_enabled")) }
        set { defaults.set(newValue, forKey: key("sync_enabled")) }
    }

    func clear() {
        for k in ["bridge_ip", "username", "clientkey", "area_id", "sync_enabled"] {
            defaults.removeObject(forKey: key(k))
        }
    }

    /// Clean up any old Keychain entries from the previous implementation.
    static func migrateFromKeychain() {
        let service = "com.velo.hue"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func key(_ k: String) -> String { prefix + k }
}
