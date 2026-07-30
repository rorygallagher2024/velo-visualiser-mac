import Foundation

struct HueBridge: Identifiable, Hashable, Sendable {
    let id: String
    let ip: String
}

struct HueChannel: Sendable {
    let channelId: Int
}

struct HueEntertainmentArea: Identifiable, Sendable {
    let id: String
    let name: String
    let channels: [HueChannel]
    let lightIds: [String]
}

struct HueCredentials: Sendable {
    let bridgeIp: String
    let username: String
    let clientKey: String
}
