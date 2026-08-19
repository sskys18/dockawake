import Foundation

/// Reads the user's own launchd jobs: the property lists in
/// `~/Library/LaunchAgents` joined with their live state from `launchctl list`,
/// plus every other non-Apple job loaded in the user's launchd domain. Apps that
/// register a background job through `SMAppService` or ship it inside their own
/// bundle never write a file into `~/Library/LaunchAgents`, so a directory-only
/// listing would hide most of what is actually running.
///
/// Collection is read-only. Apple's own agents are excluded: several hundred of
/// them would bury the handful of jobs the user can act on.
final class LaunchAgentCollector {
    static let executable = "/bin/launchctl"

    private let runner: CommandRunning
    private let directory: URL
    private let fileManager: FileManager

    init(runner: CommandRunning = CommandRunner(),
         directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents"),
         fileManager: FileManager = .default) {
        self.runner = runner
        self.directory = directory
        self.fileManager = fileManager
    }

    func collect() -> LaunchAgentStatus {
        guard let contents = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return .directoryUnreadable
        }
        let plists = contents.filter { $0.pathExtension == "plist" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let result = runner.run(
            executable: Self.executable,
            arguments: ["list"],
            outputLimit: 512 * 1024,
            timeout: 4)
        guard result.status == 0, !result.timedOut else { return .runtimeUnreadable }
        let runtime = Self.parseList(result.output)

        var rows: [LaunchAgentRow] = []
        for url in plists {
            let definition = (try? Data(contentsOf: url)).flatMap(Self.parseDefinition)
            let live = definition.flatMap { runtime[$0.label] }
            rows.append(LaunchAgentRow(
                label: definition?.label ?? "",
                fileName: url.lastPathComponent,
                program: definition?.program ?? "",
                trigger: definition?.trigger ?? "",
                pid: live?.pid,
                lastExitStatus: live?.lastExitStatus,
                isLoaded: live != nil))
        }
        let described = Set(rows.map(\.label)).subtracting([""])
        for (label, live) in runtime where !described.contains(label) && Self.isUserFacing(label) {
            rows.append(LaunchAgentRow(
                label: label,
                fileName: "",
                program: "",
                trigger: "",
                pid: live.pid,
                lastExitStatus: live.lastExitStatus,
                isLoaded: true))
        }
        return .available(rows.sorted { lhs, rhs in
            if lhs.isRunning != rhs.isRunning { return lhs.isRunning }
            if lhs.isLoaded != rhs.isLoaded { return lhs.isLoaded }
            if lhs.isInvalid != rhs.isInvalid { return rhs.isInvalid }
            return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
        })
    }

    /// `application.*` labels are transient per-launch instances of running apps,
    /// not installed jobs, so they belong in the Processes tab and not here.
    static func isUserFacing(_ label: String) -> Bool {
        !label.hasPrefix("com.apple.") && !label.hasPrefix("application.")
    }

    struct Definition: Equatable {
        let label: String
        let program: String
        let trigger: String
    }

    /// launchd itself refuses a job without a `Label`, so a plist without one has
    /// no definition and is surfaced as an invalid row instead of an invented one.
    static func parseDefinition(_ data: Data) -> Definition? {
        guard let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let fields = object as? [String: Any],
              let label = fields["Label"] as? String,
              !label.isEmpty else { return nil }
        return Definition(label: label, program: program(fields), trigger: trigger(fields))
    }

    /// One line per job as `PID<TAB>LastExitStatus<TAB>Label`. `-` means the job
    /// is loaded but not currently running. The header line carries no job.
    static func parseList(_ data: Data) -> [String: LaunchAgentRuntime] {
        guard let text = String(data: data, encoding: .utf8) else { return [:] }
        var runtime: [String: LaunchAgentRuntime] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 3 else { continue }
            let label = String(fields[2]).trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty, label != "Label" else { continue }
            runtime[label] = LaunchAgentRuntime(
                pid: Int32(fields[0].trimmingCharacters(in: .whitespaces)),
                lastExitStatus: Int32(fields[1].trimmingCharacters(in: .whitespaces)))
        }
        return runtime
    }

    private static func program(_ fields: [String: Any]) -> String {
        if let program = fields["Program"] as? String, !program.isEmpty { return program }
        if let arguments = fields["ProgramArguments"] as? [String], !arguments.isEmpty {
            return arguments.joined(separator: " ")
        }
        return ""
    }

    private static func trigger(_ fields: [String: Any]) -> String {
        var parts: [String] = []
        if fields["RunAtLoad"] as? Bool == true { parts.append("At load") }
        if let keepAlive = fields["KeepAlive"] {
            if keepAlive as? Bool == true || keepAlive is [String: Any] { parts.append("Keep alive") }
        }
        if let interval = fields["StartInterval"] as? Int { parts.append("Every \(interval)s") }
        if fields["StartCalendarInterval"] != nil { parts.append("Calendar") }
        if fields["WatchPaths"] != nil { parts.append("Watch paths") }
        return parts.isEmpty ? "Manual" : parts.joined(separator: " · ")
    }
}
