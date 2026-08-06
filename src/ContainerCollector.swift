import Foundation

/// Reads the local Docker-compatible container runtime through the `docker` CLI.
///
/// Collection is read-only. `stop(containerID:)` is the single mutating entry
/// point and runs only from an explicit dashboard action, never from the
/// refresh loop. When the CLI is absent or the daemon is unreachable the
/// collector reports that state instead of substituting an empty list, so the
/// dashboard can tell "no containers" apart from "no runtime".
final class ContainerCollector {
    /// Homebrew arm64, Homebrew x86_64, and Docker Desktop's symlink target.
    static let executableCandidates = [
        "/opt/homebrew/bin/docker",
        "/usr/local/bin/docker",
        "/usr/bin/docker"
    ]

    private let runner: CommandRunning
    private let isExecutable: (String) -> Bool

    init(runner: CommandRunning = CommandRunner(),
         isExecutable: @escaping (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) {
        self.runner = runner
        self.isExecutable = isExecutable
    }

    var executablePath: String? {
        Self.executableCandidates.first(where: isExecutable)
    }

    func collect() -> ContainerRuntimeStatus {
        guard let executable = executablePath else { return .missingCLI }
        let result = runner.run(
            executable: executable,
            arguments: ["ps", "--all", "--no-trunc", "--format", "{{json .}}"],
            outputLimit: 256 * 1024,
            timeout: 4)
        guard result.status == 0, !result.timedOut else { return .daemonUnreachable }
        return .available(Self.parse(result.output))
    }

    /// Sends the runtime's own graceful stop, which signals the container's main
    /// process and only escalates after the daemon's grace period. The timeout
    /// covers that grace period so a slow shutdown is not reported as a failure.
    func stop(containerID: String) -> Bool {
        guard let executable = executablePath, !containerID.isEmpty else { return false }
        let result = runner.run(
            executable: executable,
            arguments: ["stop", containerID],
            outputLimit: 8 * 1024,
            timeout: 30)
        return result.status == 0 && !result.timedOut
    }

    /// Parses one JSON object per line as emitted by `docker ... --format "{{json .}}"`.
    /// Malformed lines are skipped rather than failing the whole snapshot.
    static func parse(_ data: Data) -> [ContainerRow] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var rows: [ContainerRow] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let lineData = trimmed.data(using: .utf8) else { continue }
            guard let object = try? JSONSerialization.jsonObject(with: lineData),
                  let fields = object as? [String: Any] else { continue }
            guard let id = fields["ID"] as? String, !id.isEmpty else { continue }
            rows.append(ContainerRow(
                id: id,
                name: string(fields["Names"]),
                image: string(fields["Image"]),
                state: string(fields["State"]).lowercased(),
                status: string(fields["Status"]),
                ports: string(fields["Ports"])))
        }
        return rows.sorted { lhs, rhs in
            if lhs.isRunning != rhs.isRunning { return lhs.isRunning }
            return lhs.name < rhs.name
        }
    }

    private static func string(_ value: Any?) -> String {
        (value as? String) ?? ""
    }
}
