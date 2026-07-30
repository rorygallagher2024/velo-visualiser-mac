import Foundation

/// Bridge discovery, link-button pairing, and entertainment stream control.
///
/// All network calls use URLSession with a delegate that trusts the bridge's
/// self-signed LAN cert (the same approach the official Hue SDK uses).
final class HueSetupManager: @unchecked Sendable {

    private let session: URLSession
    private let delegate = LanTrustDelegate()

    init() {
        session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
    }

    // MARK: - Discovery

    /// Retained while a scan is in progress so ARC doesn't collect it.
    private var activeBrowser: BonjourBrowser?

    func discoverBridges() async -> [HueBridge] {
        var found = [String: HueBridge]()

        // N-UPnP: Philips cloud endpoint (works if bridge has internet)
        do {
            if let url = URL(string: "https://discovery.meethue.com") {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    for obj in arr {
                        if let ip = obj["internalipaddress"] as? String, !ip.isEmpty {
                            let id = (obj["id"] as? String) ?? ip
                            found[ip] = HueBridge(id: id, ip: ip)
                        }
                    }
                }
                VeloLog.write("hue", "N-UPnP found \(found.count) bridge(s)")
            }
        } catch {
            VeloLog.write("hue", "N-UPnP discovery failed: \(error.localizedDescription)")
        }

        // mDNS: NetServiceBrowser must run on a thread with an active RunLoop.
        // Schedule it on main, which always has one.
        let mdns: [HueBridge] = await withCheckedContinuation { cont in
            DispatchQueue.main.async { [weak self] in
                let browser = BonjourBrowser()
                self?.activeBrowser = browser
                browser.search(timeout: 4) { [weak self] bridges in
                    VeloLog.write("hue", "mDNS found \(bridges.count) bridge(s)")
                    self?.activeBrowser = nil
                    cont.resume(returning: bridges)
                }
            }
        }
        for b in mdns { found[b.ip] = b }

        return Array(found.values)
    }

    // MARK: - Pairing

    func pair(
        bridgeIp: String,
        maxSeconds: Int = 30,
        onCountdown: @escaping @Sendable (Int) -> Void
    ) async throws -> HueCredentials {
        let payload = try JSONSerialization.data(withJSONObject: [
            "devicetype": "velo#mac",
            "generateclientkey": true,
        ])

        for remaining in stride(from: maxSeconds, to: 0, by: -1) {
            onCountdown(remaining)

            guard let url = URL(string: "https://\(bridgeIp)/api") else {
                throw HueSetupError.badURL
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = payload
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let (data, _) = try await session.data(for: request)
            if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               let first = arr.first {
                if let success = first["success"] as? [String: Any],
                   let user = success["username"] as? String,
                   let key = success["clientkey"] as? String {
                    return HueCredentials(bridgeIp: bridgeIp, username: user, clientKey: key)
                }
                if let error = first["error"] as? [String: Any],
                   let type = error["type"] as? Int, type != 101 {
                    let desc = (error["description"] as? String) ?? "pairing error"
                    throw HueSetupError.bridgeError(desc)
                }
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw HueSetupError.timeout
    }

    // MARK: - Entertainment Areas

    func listAreas(_ creds: HueCredentials) async throws -> [HueEntertainmentArea] {
        guard let url = URL(string: "https://\(creds.bridgeIp)/clip/v2/resource/entertainment_configuration") else {
            throw HueSetupError.badURL
        }
        var req = URLRequest(url: url)
        req.setValue(creds.username, forHTTPHeaderField: "hue-application-key")

        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
            throw HueSetupError.authFailed
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = root["data"] as? [[String: Any]] else { return [] }

        return arr.compactMap { obj -> HueEntertainmentArea? in
            guard let id = obj["id"] as? String else { return nil }
            let name = (obj["metadata"] as? [String: Any])?["name"] as? String ?? "Area"
            let chArr = obj["channels"] as? [[String: Any]] ?? []
            let channels = chArr.compactMap { ch -> HueChannel? in
                guard let cid = ch["channel_id"] as? Int else { return nil }
                return HueChannel(channelId: cid)
            }
            let lsArr = obj["light_services"] as? [[String: Any]] ?? []
            let lightIds = lsArr.compactMap { $0["rid"] as? String }
            return HueEntertainmentArea(id: id, name: name, channels: channels, lightIds: lightIds)
        }
    }

    // MARK: - Stream Control

    func setStreamActive(_ creds: HueCredentials, areaId: String, active: Bool) async -> Bool {
        guard let url = URL(string: "https://\(creds.bridgeIp)/clip/v2/resource/entertainment_configuration/\(areaId)") else {
            return false
        }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue(creds.username, forHTTPHeaderField: "hue-application-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "action": active ? "start" : "stop"
        ])

        do {
            let (_, response) = try await session.data(for: req)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            VeloLog.write("hue", "setStreamActive(\(active)) failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Set light state for all lights in `lightIds` via CLIP v2 REST.
    /// Pass only the properties you want to change; omitted ones stay as-is.
    func controlLights(
        _ creds: HueCredentials,
        lightIds: [String],
        on: Bool? = nil,
        brightness: Int? = nil,
        mirek: Int? = nil,
        x: Double? = nil,
        y: Double? = nil
    ) async {
        var body: [String: Any] = [:]
        if let on { body["on"] = ["on": on] }
        if let brightness { body["dimming"] = ["brightness": brightness] }
        if let mirek { body["color_temperature"] = ["mirek": mirek] }
        if let x, let y { body["color"] = ["xy": ["x": x, "y": y]] }
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return }

        for id in lightIds {
            guard let url = URL(string: "https://\(creds.bridgeIp)/clip/v2/resource/light/\(id)") else { continue }
            var req = URLRequest(url: url)
            req.httpMethod = "PUT"
            req.setValue(creds.username, forHTTPHeaderField: "hue-application-key")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = bodyData
            _ = try? await session.data(for: req)
        }
    }

    /// Quick reachability check. Returns RTT in ms, or nil if unreachable.
    func pingBridge(_ creds: HueCredentials) async -> Int? {
        guard let url = URL(string: "https://\(creds.bridgeIp)/clip/v2/resource/bridge") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 3)
        req.setValue(creds.username, forHTTPHeaderField: "hue-application-key")
        let t0 = DispatchTime.now().uptimeNanoseconds
        do {
            let (_, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return Int((DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)
        } catch {
            return nil
        }
    }
}

enum HueSetupError: Error, LocalizedError {
    case badURL
    case timeout
    case authFailed
    case bridgeError(String)

    var errorDescription: String? {
        switch self {
        case .badURL: "Invalid bridge address."
        case .timeout: "Timed out. Press the bridge button and try again."
        case .authFailed: "Bridge rejected credentials. Re-pair the bridge."
        case .bridgeError(let msg): msg
        }
    }
}

// MARK: - TLS trust for the bridge's self-signed LAN cert

private final class LanTrustDelegate: NSObject, URLSessionDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }
}

// MARK: - Bonjour mDNS discovery

private final class BonjourBrowser: NSObject, NetServiceBrowserDelegate, NetServiceDelegate, @unchecked Sendable {
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var found: [HueBridge] = []
    private var completion: (([HueBridge]) -> Void)?

    func search(timeout: TimeInterval, completion: @escaping ([HueBridge]) -> Void) {
        self.completion = completion
        browser.delegate = self
        browser.searchForServices(ofType: "_hue._tcp.", inDomain: "local.")
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.browser.stop()
            self?.finish()
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 3)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let data = sender.addresses else { return }
        for addr in data {
            let ip = addr.withUnsafeBytes { ptr -> String? in
                let sa = ptr.baseAddress!.assumingMemoryBound(to: sockaddr.self)
                if sa.pointee.sa_family == UInt8(AF_INET) {
                    let sin = ptr.baseAddress!.assumingMemoryBound(to: sockaddr_in.self)
                    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    var inAddr = sin.pointee.sin_addr
                    inet_ntop(AF_INET, &inAddr, &buf, socklen_t(INET_ADDRSTRLEN))
                    return String(decoding: buf.prefix(while: { $0 != 0 }).map(UInt8.init), as: UTF8.self)
                }
                return nil
            }
            if let ip {
                found.append(HueBridge(id: sender.name, ip: ip))
                return
            }
        }
    }

    private func finish() {
        completion?(found)
        completion = nil
    }
}
