import Foundation

/// Blocking REST client for a single Nanoleaf device's local HTTP API.
/// All calls run on a background thread — never call from main.
enum NanoleafApi {

    static let defaultPort: Int = 16021
    private static let timeoutSec: TimeInterval = 2
    private static let defaultUdpPort: Int = 60222

    // MARK: - Auth

    /// Request an auth token while the device's pairing window is open.
    /// POST http://{host}:{port}/api/v1/new → {"auth_token": "..."}
    static func requestToken(host: String, port: Int) -> String? {
        guard let url = URL(string: "http://\(host):\(port)/api/v1/new") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: timeoutSec)
        req.httpMethod = "POST"
        let (data, resp) = syncRequest(req)
        guard let http = resp as? HTTPURLResponse,
              (200...201).contains(http.statusCode),
              let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["auth_token"] as? String
        else { return nil }
        return token
    }

    // MARK: - Device info

    /// Fetch the user-visible device name. Returns nil if unreachable or token invalid.
    static func fetchName(host: String, port: Int, token: String) -> String? {
        guard let data = get(host: host, port: port, token: token, path: "") else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["name"] as? String
        else { return nil }
        return name
    }

    /// Fetch panel IDs for External Control streaming. Excludes panel ID 0 (controller module).
    static func fetchPanelIds(host: String, port: Int, token: String) -> [Int]? {
        guard let data = get(host: host, port: port, token: token, path: "") else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let layout = json["panelLayout"] as? [String: Any],
              let inner = layout["layout"] as? [String: Any],
              let positions = inner["positionData"] as? [[String: Any]]
        else { return nil }
        return positions.compactMap { ($0["panelId"] as? Int) }.filter { $0 != 0 }
    }

    // MARK: - External Control

    /// Enable External Control v2 and return the UDP streaming port.
    static func enableExtControl(host: String, port: Int, token: String) -> Int? {
        guard let url = URL(string: "http://\(host):\(port)/api/v1/\(token)/effects") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: timeoutSec)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "write": [
                "command": "display",
                "animType": "extControl",
                "extControlVersion": "v2"
            ]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let (data, resp) = syncRequest(req)
        guard let http = resp as? HTTPURLResponse,
              (200...204).contains(http.statusCode)
        else { return nil }
        if let data,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let udpPort = json["streamControlPort"] as? Int {
            return udpPort
        }
        return defaultUdpPort
    }

    // MARK: - State control

    /// Set device state: on/off, brightness (0..1), hue (0..360), saturation (0..1).
    static func setState(host: String, port: Int, token: String,
                         on: Bool? = nil, bri: Float? = nil,
                         hue: Float? = nil, sat: Float? = nil) {
        guard let url = URL(string: "http://\(host):\(port)/api/v1/\(token)/state") else { return }
        var req = URLRequest(url: url, timeoutInterval: timeoutSec)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var state: [String: Any] = [:]
        if let on { state["on"] = ["value": on] }
        if let bri { state["brightness"] = ["value": max(1, min(100, Int(bri * 100)))] }
        if let hue { state["hue"] = ["value": Int(hue) % 360] }
        if let sat { state["sat"] = ["value": max(0, min(100, Int(sat * 100)))] }
        req.httpBody = try? JSONSerialization.data(withJSONObject: state)
        _ = syncRequest(req)
    }

    // MARK: - Helpers

    private static func get(host: String, port: Int, token: String, path: String) -> Data? {
        guard let url = URL(string: "http://\(host):\(port)/api/v1/\(token)/\(path)") else { return nil }
        let req = URLRequest(url: url, timeoutInterval: timeoutSec)
        let (data, resp) = syncRequest(req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return data
    }

    private static func syncRequest(_ request: URLRequest) -> (Data?, URLResponse?) {
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var resultData: Data?
        nonisolated(unsafe) var resultResp: URLResponse?
        URLSession.shared.dataTask(with: request) { data, resp, _ in
            resultData = data
            resultResp = resp
            sem.signal()
        }.resume()
        sem.wait()
        return (resultData, resultResp)
    }
}
