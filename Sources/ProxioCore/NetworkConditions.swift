import Foundation

/// A simulated link: extra round-trip latency and bandwidth caps, or no connectivity at all.
public struct NetworkProfile: Sendable, Equatable, Hashable, Codable, Identifiable {
    public var name: String
    /// Added round trip; each direction waits half of it.
    public var latencyMs: Int
    /// 0 means unlimited.
    public var downKbps: Int
    public var upKbps: Int
    public var offline: Bool

    public var id: String { name }

    public init(name: String, latencyMs: Int = 0, downKbps: Int = 0, upKbps: Int = 0, offline: Bool = false) {
        self.name = name
        self.latencyMs = latencyMs
        self.downKbps = downKbps
        self.upKbps = upKbps
        self.offline = offline
    }

    /// True when the profile changes nothing.
    public var isTransparent: Bool { !offline && latencyMs <= 0 && downKbps <= 0 && upKbps <= 0 }

    public static let none = NetworkProfile(name: "No Throttling")
    public static let offlineProfile = NetworkProfile(name: "Offline", offline: true)
    public static let edge = NetworkProfile(name: "Edge", latencyMs: 800, downKbps: 240, upKbps: 200)
    public static let slow3G = NetworkProfile(name: "Slow 3G", latencyMs: 400, downKbps: 400, upKbps: 400)
    public static let fast3G = NetworkProfile(name: "Fast 3G", latencyMs: 150, downKbps: 1_600, upKbps: 750)
    public static let lte = NetworkProfile(name: "4G / LTE", latencyMs: 70, downKbps: 12_000, upKbps: 6_000)
    public static let poorWiFi = NetworkProfile(name: "Poor Wi-Fi", latencyMs: 120, downKbps: 2_000, upKbps: 1_000)

    public static let presets: [NetworkProfile] = [.none, .offlineProfile, .edge, .slow3G, .fast3G, .lte, .poorWiFi]

    /// Bytes per second, or nil when unlimited.
    public func bytesPerSecond(download: Bool) -> Double? {
        let kbps = download ? downKbps : upKbps
        return kbps > 0 ? Double(kbps) * 125 : nil
    }
}

/// The live profile shared by every connection; can be changed while the proxy runs.
public final class NetworkConditions: @unchecked Sendable {
    private let lock = NSLock()
    private var current: NetworkProfile

    public init(_ profile: NetworkProfile = .none) { current = profile }

    public var profile: NetworkProfile {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}
