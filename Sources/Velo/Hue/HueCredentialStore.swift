import Foundation
import Security

/// Keychain-backed persistence for Hue pairing secrets and the selected area.
final class HueCredentialStore: Sendable {

    private let service = "com.velo.hue"

    func save(_ creds: HueCredentials) {
        set("bridge_ip", creds.bridgeIp)
        set("username", creds.username)
        set("clientkey", creds.clientKey)
    }

    func load() -> HueCredentials? {
        guard let ip = get("bridge_ip"),
              let user = get("username"),
              let key = get("clientkey") else { return nil }
        return HueCredentials(bridgeIp: ip, username: user, clientKey: key)
    }

    var selectedAreaId: String? {
        get { get("area_id") }
        set {
            if let v = newValue { set("area_id", v) } else { delete("area_id") }
        }
    }

    var syncEnabled: Bool {
        get { get("sync_enabled") == "1" }
        set { set("sync_enabled", newValue ? "1" : "0") }
    }

    func clear() {
        for key in ["bridge_ip", "username", "clientkey", "area_id", "sync_enabled"] {
            delete(key)
        }
    }

    private func set(_ key: String, _ value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    private func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
