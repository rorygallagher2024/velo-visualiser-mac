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
        // Force the write now. A credential that only exists in the in-memory
        // domain is a credential that works for the rest of this session and is
        // gone by the next launch.
        defaults.synchronize()
        VeloLog.write("hue", "saved creds ip=\(creds.bridgeIp) "
                      + "user=\(Self.fingerprint(creds.username)) "
                      + "clientkey=\(Self.fingerprint(creds.clientKey))")
    }

    func load() -> HueCredentials? {
        guard let ip = defaults.string(forKey: key("bridge_ip")),
              let user = defaults.string(forKey: key("username")),
              let ck = defaults.string(forKey: key("clientkey")) else {
            VeloLog.write("hue", "no stored creds "
                          + "(ip=\(defaults.string(forKey: key("bridge_ip")) != nil) "
                          + "user=\(defaults.string(forKey: key("username")) != nil) "
                          + "clientkey=\(defaults.string(forKey: key("clientkey")) != nil))")
            return nil
        }
        VeloLog.write("hue", "loaded creds ip=\(ip) "
                      + "user=\(Self.fingerprint(user)) "
                      + "clientkey=\(Self.fingerprint(ck))")
        return HueCredentials(bridgeIp: ip, username: user, clientKey: ck)
    }

    /// Enough of a secret to tell two of them apart in a log, and no more.
    /// Comparing the fingerprint written at pairing against the one read back
    /// at the next launch says whether a credential survived storage intact.
    static func fingerprint(_ s: String) -> String {
        guard s.count > 8 else { return "len=\(s.count) <short>" }
        return "len=\(s.count) \(s.prefix(4))…\(s.suffix(4))"
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
