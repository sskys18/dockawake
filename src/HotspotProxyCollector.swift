import Foundation

/// What the Hotspot Proxy watcher (`mac/hotspot-tun.sh` in the hotspot-proxy repo) decided on its
/// last run. The watcher rewrites its status file every 30 seconds.
enum HotspotProxyStatus: Equatable {
    /// No status file: the watcher is not installed.
    case notInstalled
    /// The file exists but cannot be read or parsed.
    case unreadable
    /// The watcher stopped rewriting the file.
    case stale(since: Date)
    /// Not on our own iPhone hotspot; the Mac uses its normal network.
    case off
    /// All traffic goes through the phone's proxy, verified on the last run.
    case proxied(phone: String)
    /// On our hotspot, but the phone app cannot reach the internet, so the Mac stays direct.
    case upstreamFailed(phone: String)
    /// On our hotspot, but the tunnel could not take traffic; retried after rejoining the hotspot.
    case routeFailed(phone: String)
}

extension HotspotProxyStatus {
    enum Tone: Equatable { case good, warning, bad, neutral }

    /// One line for the Network card; nil hides the row on Macs without the watcher.
    var summary: (text: String, tone: Tone)? {
        switch self {
        case .notInstalled: return nil
        case .unreadable: return ("Status file unreadable", .bad)
        case let .stale(since):
            return ("Watcher not running since \(since.formatted(date: .omitted, time: .shortened))", .bad)
        case .off: return ("Off, not on your iPhone hotspot", .neutral)
        case .proxied: return ("On, traffic goes through the iPhone", .good)
        case .upstreamFailed: return ("Direct, the iPhone app can't reach the internet", .warning)
        case .routeFailed: return ("Direct, tunnel failed (rejoin the hotspot to retry)", .warning)
        }
    }

    /// The phone address the watcher verified, for the row's tooltip.
    var phone: String? {
        switch self {
        case let .proxied(phone), let .upstreamFailed(phone), let .routeFailed(phone): return phone
        case .notInstalled, .unreadable, .stale, .off: return nil
        }
    }
}

struct HotspotProxyCollector {
    static let defaultPath = "/var/run/hotspot-tun.json"
    /// Three missed 30-second runs, with room for the watcher's own network checks.
    static let maxAge: TimeInterval = 120

    private struct File: Decodable {
        let state: String
        let phone: String
        let updated: TimeInterval
    }

    let path: String
    let now: () -> Date

    init(path: String = HotspotProxyCollector.defaultPath, now: @escaping () -> Date = Date.init) {
        self.path = path
        self.now = now
    }

    func collect() -> HotspotProxyStatus {
        guard FileManager.default.fileExists(atPath: path) else { return .notInstalled }
        guard let data = FileManager.default.contents(atPath: path),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return .unreadable }
        let updated = Date(timeIntervalSince1970: file.updated)
        guard now().timeIntervalSince(updated) <= Self.maxAge else { return .stale(since: updated) }
        switch file.state {
        case "off": return .off
        case "proxied": return .proxied(phone: file.phone)
        case "upstream-failed": return .upstreamFailed(phone: file.phone)
        case "route-failed": return .routeFailed(phone: file.phone)
        default: return .unreadable
        }
    }
}
