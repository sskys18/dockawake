import Foundation

/// Routes the Mac's internet traffic through the OCI Tailscale exit node, whose exit
/// traffic leaves via the Surfshark Tokyo WireGuard tunnel (see the exit node setup).
enum ExitNodeState: Equatable {
    case off
    case on
    /// Another exit node is selected; toggling replaces it with the Surfshark node.
    case other(String)
    case unavailable(String)
}

final class ExitNodeController {
    static let tailscalePath = "/usr/local/bin/tailscale"
    static let nodeIP = "100.64.0.1"

    private let runner: CommandRunning
    private let queue = DispatchQueue(label: "com.dockawake.exitnode", qos: .userInitiated)

    init(runner: CommandRunning = CommandRunner()) {
        self.runner = runner
    }

    func currentState() -> ExitNodeState {
        let result = runner.run(executable: Self.tailscalePath, arguments: ["status", "--json"], outputLimit: 1024 * 1024, timeout: 5)
        guard result.succeeded else { return .unavailable("tailscale status failed") }
        return Self.parse(result.output)
    }

    /// Selects or clears the exit node off the main thread and reports the state read back afterwards.
    func setEnabled(_ enabled: Bool, completion: @escaping (ExitNodeState) -> Void) {
        queue.async {
            let arg = enabled ? "--exit-node=\(Self.nodeIP)" : "--exit-node="
            let result = self.runner.run(executable: Self.tailscalePath, arguments: ["set", arg], outputLimit: 64 * 1024, timeout: 10)
            let state = result.succeeded ? self.currentState() : .unavailable("tailscale set failed")
            DispatchQueue.main.async { completion(state) }
        }
    }

    static func parse(_ data: Data) -> ExitNodeState {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .unavailable("unreadable tailscale status")
        }
        if let backend = root["BackendState"] as? String, backend != "Running" {
            return .unavailable("Tailscale \(backend)")
        }
        let peers = (root["Peer"] as? [String: [String: Any]])?.values ?? [:].values
        guard let active = peers.first(where: { $0["ExitNode"] as? Bool == true }) else { return .off }
        let ips = active["TailscaleIPs"] as? [String] ?? []
        if ips.contains(nodeIP) { return .on }
        return .other(active["HostName"] as? String ?? "unknown")
    }
}
