import Foundation

/// Routes the Mac's internet traffic through the OCI Tailscale exit node, whose exit traffic
/// leaves via a Surfshark WireGuard tunnel (node IP from `LocalConfig`). The country is
/// switched on OCI through a forced-command SSH key that can only run `surfshark-switch`.
enum ExitNodeState: Equatable {
    case off
    /// Exit node selected; `server` is the Surfshark server the OCI tunnel uses.
    case on(server: String)
    /// Another exit node is selected; picking a country replaces it.
    case other(String)
    case unavailable(String)
}

struct SurfsharkServer: Equatable {
    let id: String
    let label: String

    static let all = [
        SurfsharkServer(id: "kr-seo", label: "Korea · Seoul"),
        SurfsharkServer(id: "jp-tok", label: "Japan · Tokyo"),
        SurfsharkServer(id: "sg-sng", label: "Singapore"),
        SurfsharkServer(id: "us-lax", label: "US · Los Angeles"),
        SurfsharkServer(id: "uk-lon", label: "UK · London"),
    ]

    static func label(for id: String) -> String {
        all.first { $0.id == id }?.label ?? id
    }
}

final class ExitNodeController {
    static let tailscalePath = "/usr/local/bin/tailscale"
    static let sshPath = "/usr/bin/ssh"
    static let switchKey = NSHomeDirectory() + "/.ssh/dockawake_surfshark"

    private let runner: CommandRunning
    private let nodeIP: String?
    private let queue = DispatchQueue(label: "com.dockawake.exitnode", qos: .userInitiated)

    init(nodeIP: String?, runner: CommandRunning = CommandRunner()) {
        self.nodeIP = nodeIP
        self.runner = runner
    }

    func currentState() -> ExitNodeState {
        guard let nodeIP else { return .unavailable("not configured") }
        let result = runner.run(executable: Self.tailscalePath, arguments: ["status", "--json"], outputLimit: 1024 * 1024, timeout: 5)
        guard result.succeeded else { return .unavailable("tailscale status failed") }
        let state = Self.parse(result.output, nodeIP: nodeIP)
        guard state == .on(server: "") else { return state }
        let server = remote("status")
        return server.map { .on(server: $0) } ?? .unavailable("OCI unreachable")
    }

    /// `server == nil` turns the exit node off; otherwise switches OCI to that server, then selects the exit node.
    /// Runs off the main thread and reports the state read back afterwards.
    func select(server: String?, completion: @escaping (ExitNodeState) -> Void) {
        queue.async {
            let state: ExitNodeState
            if let nodeIP = self.nodeIP, let server {
                if self.remote(server) != server {
                    state = .unavailable("switch to \(server) failed")
                } else {
                    state = self.setExitNode("--exit-node=\(nodeIP)")
                }
            } else if self.nodeIP == nil {
                state = .unavailable("not configured")
            } else {
                state = self.setExitNode("--exit-node=")
            }
            DispatchQueue.main.async { completion(state) }
        }
    }

    private func setExitNode(_ arg: String) -> ExitNodeState {
        let result = runner.run(executable: Self.tailscalePath, arguments: ["set", arg], outputLimit: 64 * 1024, timeout: 10)
        return result.succeeded ? currentState() : .unavailable("tailscale set failed")
    }

    private func remote(_ command: String) -> String? {
        let result = runner.run(
            executable: Self.sshPath,
            arguments: ["-i", Self.switchKey, "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
                        "ubuntu@\(nodeIP ?? "")", command],
            outputLimit: 4096,
            timeout: 30)
        guard result.succeeded else { return nil }
        let text = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Reads Tailscale's view only. `.on(server: "")` means our node is selected; the server comes from OCI.
    static func parse(_ data: Data, nodeIP: String) -> ExitNodeState {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .unavailable("unreadable tailscale status")
        }
        if let backend = root["BackendState"] as? String, backend != "Running" {
            return .unavailable("Tailscale \(backend)")
        }
        let peers = (root["Peer"] as? [String: [String: Any]])?.values ?? [:].values
        guard let active = peers.first(where: { $0["ExitNode"] as? Bool == true }) else { return .off }
        let ips = active["TailscaleIPs"] as? [String] ?? []
        if ips.contains(nodeIP) { return .on(server: "") }
        return .other(active["HostName"] as? String ?? "unknown")
    }
}
