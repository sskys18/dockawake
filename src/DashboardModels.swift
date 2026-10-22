import Foundation

/// A value that may be currently available, unsupported or failed, or not yet known.
enum Availability<Value: Equatable>: Equatable {
    case available(Value)
    case unavailable
    case unknown

    var value: Value? {
        guard case let .available(value) = self else { return nil }
        return value
    }

    var displayText: String {
        switch self {
        case .available:
            return ""
        case .unavailable:
            return "Unavailable"
        case .unknown:
            return "Unknown"
        }
    }
}

struct MetricDisplay: Equatable {
    let value: Double
    let text: String
    /// Absolute context for the percentage, such as "12 GB of 16 GB".
    let detail: String?

    init(value: Double, text: String, detail: String? = nil) {
        self.value = value
        self.text = text
        self.detail = detail
    }
}

/// One timestamped value in a chart series.
struct HistorySample: Equatable, Identifiable {
    let date: Date
    let value: Double

    var id: Date { date }
}

/// A fixed-capacity, oldest-first series. Appending past capacity drops the
/// oldest samples so a long-running app keeps a bounded chart window.
struct BoundedHistory: Equatable {
    let capacity: Int
    private(set) var samples: [HistorySample] = []

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    mutating func append(_ sample: HistorySample) {
        samples.append(sample)
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
    }

    mutating func removeAll() {
        samples.removeAll()
    }
}

/// How the machine is currently powered, which changes the moment the charger
/// is plugged or unplugged even though the charge percentage does not.
enum BatteryPower: Equatable {
    case charging
    case pluggedNotCharging
    case onBattery

    var text: String {
        switch self {
        case .charging: return "Charging"
        case .pluggedNotCharging: return "Plugged in"
        case .onBattery: return "On battery"
        }
    }
}

struct SystemSummarySnapshot: Equatable {
    let timestamp: Date
    let cpu: Availability<MetricDisplay>
    let memory: Availability<MetricDisplay>
    let storage: Availability<MetricDisplay>
    let battery: Availability<MetricDisplay>
    let batteryPower: Availability<BatteryPower>

    init(
        timestamp: Date,
        cpu: Availability<MetricDisplay>,
        memory: Availability<MetricDisplay>,
        storage: Availability<MetricDisplay>,
        battery: Availability<MetricDisplay>,
        batteryPower: Availability<BatteryPower> = .unavailable
    ) {
        self.timestamp = timestamp
        self.cpu = cpu
        self.memory = memory
        self.storage = storage
        self.battery = battery
        self.batteryPower = batteryPower
    }
}

/// The immutable data required by the status strip and dashboard summary.
typealias DashboardSnapshot = SystemSummarySnapshot

struct NetworkInterfaceSnapshot: Equatable, Identifiable {
    let name: String
    let flags: UInt32
    let addresses: [String]
    let linkSpeedBitsPerSecond: Availability<UInt64>
    let receivedBytes: Availability<UInt64>
    let sentBytes: Availability<UInt64>
    let receivedRateBytesPerSecond: Availability<Double>
    let sentRateBytesPerSecond: Availability<Double>

    var id: String { name }

    var addressesText: String {
        addresses.isEmpty ? "N/A" : addresses.joined(separator: ", ")
    }

    var linkSpeedText: String {
        Self.text(for: linkSpeedBitsPerSecond, formatter: DashboardFormat.bitRate)
    }

    var receivedRateText: String {
        Self.text(for: receivedRateBytesPerSecond, formatter: DashboardFormat.rate)
    }

    var sentRateText: String {
        Self.text(for: sentRateBytesPerSecond, formatter: DashboardFormat.rate)
    }

    var receivedTotalText: String {
        Self.text(for: receivedBytes, formatter: DashboardFormat.bytes)
    }

    var sentTotalText: String {
        Self.text(for: sentBytes, formatter: DashboardFormat.bytes)
    }

    private static func text<Value>(for availability: Availability<Value>, formatter: (Value) -> String) -> String {
        switch availability {
        case let .available(value): return formatter(value)
        case .unavailable: return "N/A"
        case .unknown: return "Unknown"
        }
    }
}

struct ProcessIdentity: Hashable, Comparable {
    let pid: Int32
    let startSeconds: Int64
    let startMicroseconds: Int32

    static func < (lhs: ProcessIdentity, rhs: ProcessIdentity) -> Bool {
        if lhs.pid != rhs.pid { return lhs.pid < rhs.pid }
        if lhs.startSeconds != rhs.startSeconds { return lhs.startSeconds < rhs.startSeconds }
        return lhs.startMicroseconds < rhs.startMicroseconds
    }
}

struct ListeningPort: Hashable, Identifiable {
    let protocolName: String
    let address: String
    let port: UInt16
    let fileDescriptor: Int32?

    var id: String {
        "\(protocolName):\(address):\(port):\(fileDescriptor.map(String.init) ?? "")"
    }

    var displayText: String {
        "\(protocolName) \(DashboardFormat.address(address, port: port))"
    }
}

struct ProcessRow: Equatable, Identifiable {
    let id: ProcessIdentity
    let name: String
    /// Working directory of the process. Interpreter processes such as bun or
    /// python all share one executable name, so the directory is the only thing
    /// that says which project a given instance is actually running.
    let directory: Availability<String>
    /// Full argv. Like the directory, macOS hands it out only for processes
    /// this user owns.
    let arguments: Availability<[String]>
    let cpuPercent: Availability<Double>
    let memoryBytes: Availability<UInt64>
    let energyProxyPercent: Availability<Double>
    let ports: Availability<[ListeningPort]>
    let missingRefreshCount: Int

    var isRetainedMissing: Bool { missingRefreshCount > 0 }
    /// The script an interpreter runs, so ten `bun` rows read as `gjc (bun)`,
    /// `gjc sdk (bun)`, and so on.
    var displayName: String { ProcessLabel.displayName(name: name, arguments: arguments.value) }
    var commandText: String {
        DashboardFormat.text(arguments) { $0.map(DashboardFormat.homeRelativePath).joined(separator: " ") }
    }
    var cpuText: String { DashboardFormat.text(cpuPercent, formatter: DashboardFormat.processPercent) }
    var memoryText: String { DashboardFormat.text(memoryBytes, formatter: DashboardFormat.bytes) }
    var energyProxyText: String { DashboardFormat.text(energyProxyPercent, formatter: DashboardFormat.percent) }
    var directoryText: String { DashboardFormat.text(directory, formatter: DashboardFormat.homeRelativePath) }
}

enum ProcessLabel {
    /// Runtimes whose executable name says nothing about the program they run.
    static let interpreters: Set<String> = ["bun", "node", "deno", "python", "ruby", "perl", "php"]
    /// Runner verbs that precede the real script or package name.
    private static let runnerVerbs: Set<String> = ["run", "x", "exec"]
    private static let scriptExtensions: Set<String> = ["js", "mjs", "cjs", "ts", "mts", "tsx", "py", "rb", "pl", "php"]

    static func displayName(name: String, arguments: [String]?) -> String {
        guard isInterpreter(name), let arguments, arguments.count > 1 else { return name }
        guard var scriptIndex = arguments.indices.dropFirst().first(where: {
            let argument = arguments[$0].trimmingCharacters(in: .whitespaces)
            return !argument.isEmpty && !argument.hasPrefix("-")
        }) else {
            // A process that rewrote its own title, such as vitest's
            // `node (vitest)`, blanks the rest of argv; the title is the label.
            let title = arguments[0].trimmingCharacters(in: .whitespaces)
            return title.hasPrefix(name + " ") && !title.contains("/") ? title : name
        }
        if runnerVerbs.contains(arguments[scriptIndex]), scriptIndex + 1 < arguments.count {
            scriptIndex += 1
        }
        var label = programName(arguments[scriptIndex])
        // One subcommand word keeps a CLI's modes apart (`gjc` vs `gjc sdk`)
        // without turning the label into the whole command line. Only the word
        // right after the script counts, so a flag's value is never mistaken for one.
        if scriptIndex + 1 < arguments.count, isSubcommand(arguments[scriptIndex + 1]) {
            label += " \(arguments[scriptIndex + 1])"
        }
        return "\(label) (\(name))"
    }

    private static func isInterpreter(_ name: String) -> Bool {
        // python3, python3.12 and similar versioned names count as python.
        let base = name.lowercased().prefix { !$0.isNumber && $0 != "." }
        return interpreters.contains(String(base))
    }

    private static func programName(_ path: String) -> String {
        let file = (path as NSString).lastPathComponent
        let ext = (file as NSString).pathExtension.lowercased()
        guard scriptExtensions.contains(ext) else { return file }
        let stem = (file as NSString).deletingPathExtension
        // A package entry point such as dist/cli.js or index.ts is named by its package.
        guard ["index", "cli", "main"].contains(stem.lowercased()) else { return stem }
        let components = (path as NSString).pathComponents.dropLast()
        return components.last { !["dist", "src", "bin", "build", "lib", "out", "/"].contains($0) } ?? stem
    }

    private static func isSubcommand(_ word: String) -> Bool {
        word.count <= 24 && word.allSatisfy { $0.isLetter || $0 == "-" || $0 == "_" } && word.first?.isLetter == true
    }
}

struct PowerAssertionRow: Equatable, Identifiable {
    let type: String
    let ownerPID: Int32?
    let ownerName: String?
    let reason: String?

    var id: String {
        "\(type):\(ownerPID.map(String.init) ?? ""):\(ownerName ?? ""):\(reason ?? "")"
    }
}

struct ContainerRow: Equatable, Identifiable {
    let id: String
    let name: String
    let image: String
    let state: String
    let status: String
    let ports: String

    var isRunning: Bool { state == "running" }

    /// Docker accepts any unambiguous prefix, and the full 64-character ID is
    /// unreadable in a table, so the short form is display-only.
    var shortID: String { String(id.prefix(12)) }

    var displayName: String { name.isEmpty ? shortID : name }
    var portsText: String { ports.isEmpty ? "None" : ports }
    var stateText: String { state.isEmpty ? "Unknown" : state }
}

/// Distinguishes "no containers" from "no runtime", which the dashboard shows
/// as different text rather than an empty table in both cases.
enum ContainerRuntimeStatus: Equatable {
    case missingCLI
    case daemonUnreachable
    case available([ContainerRow])

    var rows: [ContainerRow] {
        guard case let .available(rows) = self else { return [] }
        return rows
    }

    var runningCount: Int { rows.filter(\.isRunning).count }

    var summaryText: String {
        switch self {
        case .missingCLI:
            return "No docker CLI found"
        case .daemonUnreachable:
            return "Runtime not running"
        case let .available(rows):
            let running = rows.filter(\.isRunning).count
            return "\(running) running · \(rows.count) total"
        }
    }
}

struct LaunchAgentRuntime: Equatable {
    let pid: Int32?
    let lastExitStatus: Int32?
}

struct LaunchAgentRow: Equatable, Identifiable {
    let label: String
    let fileName: String
    let program: String
    let trigger: String
    let pid: Int32?
    let lastExitStatus: Int32?
    let isLoaded: Bool

    /// One directory cannot hold two files of the same name, and an invalid job
    /// has no label to identify it by, so the file name is the stable identity.
    var id: String { fileName }
    var isRunning: Bool { pid != nil }

    /// launchd refuses a job without a Label, so such a file is listed as invalid
    /// rather than hidden from the user who put it in the directory.
    var isInvalid: Bool { label.isEmpty }
    var labelText: String { label.isEmpty ? "(no Label)" : label }

    /// A job loaded from somewhere other than ~/Library/LaunchAgents: registered
    /// by an app through SMAppService, submitted by a running process, or
    /// bootstrapped from a property list elsewhere on disk. Naming one of those
    /// would need a per-job `launchctl print`, so the row says only what is known.
    var hasLocalFile: Bool { !fileName.isEmpty }
    var sourceText: String { hasLocalFile ? fileName : "Elsewhere" }

    /// Only a local file tells us what the job runs and when. For the rest the
    /// live state is all launchd handed over, and Unknown says exactly that.
    var triggerText: String { hasLocalFile ? trigger : "Unknown" }

    var stateText: String {
        if isInvalid { return "Invalid" }
        if isRunning { return "Running" }
        return isLoaded ? "Loaded" : "Not loaded"
    }

    var pidText: String { pid.map(String.init) ?? "-" }

    var programText: String {
        guard hasLocalFile else { return "Unknown" }
        return program.isEmpty ? "N/A" : program
    }

    /// launchctl reports the last exit status only for a job it knows about, so
    /// an unloaded job shows nothing rather than a fabricated success.
    var lastExitText: String {
        guard let lastExitStatus else { return "-" }
        return String(lastExitStatus)
    }

    var failedLastRun: Bool { (lastExitStatus ?? 0) != 0 }
}

/// Distinguishes "no user launch agents" from "could not read them", which the
/// dashboard shows as different text rather than an empty table in both cases.
enum LaunchAgentStatus: Equatable {
    case directoryUnreadable
    case runtimeUnreadable
    case available([LaunchAgentRow])

    var rows: [LaunchAgentRow] {
        guard case let .available(rows) = self else { return [] }
        return rows
    }

    var runningCount: Int { rows.filter(\.isRunning).count }

    var summaryText: String {
        switch self {
        case .directoryUnreadable:
            return "No ~/Library/LaunchAgents"
        case .runtimeUnreadable:
            return "launchctl unavailable"
        case let .available(rows):
            let running = rows.filter(\.isRunning).count
            let loaded = rows.filter(\.isLoaded).count
            let invalid = rows.filter(\.isInvalid).count
            guard invalid == 0 else {
                return "\(running) running · \(loaded) loaded · \(rows.count) total · \(invalid) invalid"
            }
            return "\(running) running · \(loaded) loaded · \(rows.count) total"
        }
    }
}

/// Combined receive and send rate across interfaces that carry an address.
/// The two dozen empty virtual interfaces macOS creates would otherwise bury
/// the real number, and loopback traffic never leaves the Mac.
struct NetworkThroughput: Equatable {
    let receivedBytesPerSecond: Double
    let sentBytesPerSecond: Double

    /// Nil when no addressed interface exists, so the caller shows N/A rather
    /// than a fabricated zero.
    static func aggregate(_ interfaces: [NetworkInterfaceSnapshot]) -> NetworkThroughput? {
        let active = activeInterfaces(interfaces)
        guard !active.isEmpty else { return nil }
        return NetworkThroughput(
            receivedBytesPerSecond: active.compactMap(\.receivedRateBytesPerSecond.value).reduce(0, +),
            sentBytesPerSecond: active.compactMap(\.sentRateBytesPerSecond.value).reduce(0, +))
    }

    static func activeInterfaces(_ interfaces: [NetworkInterfaceSnapshot]) -> [NetworkInterfaceSnapshot] {
        interfaces.filter { !$0.addresses.isEmpty && $0.name != "lo0" }
    }
}

enum TopConsumers {
    /// The heaviest live processes by the given measure. Exited and unmeasured
    /// processes are left out because a bar needs a real value.
    static func byCPU(_ rows: [ProcessRow], limit: Int) -> [ProcessRow] {
        top(rows, limit: limit) { $0.cpuPercent.value }
    }

    static func byMemory(_ rows: [ProcessRow], limit: Int) -> [ProcessRow] {
        top(rows, limit: limit) { $0.memoryBytes.value.map(Double.init) }
    }

    private static func top(_ rows: [ProcessRow], limit: Int, measure: (ProcessRow) -> Double?) -> [ProcessRow] {
        rows.compactMap { row -> (ProcessRow, Double)? in
            guard !row.isRetainedMissing, let value = measure(row), value > 0 else { return nil }
            return (row, value)
        }
        .sorted { $0.1 == $1.1 ? $0.0.id < $1.0.id : $0.1 > $1.1 }
        .prefix(limit)
        .map(\.0)
    }
}

struct DetailSnapshot: Equatable {
    let generation: UInt64
    let timestamp: Date
    let interfaces: [NetworkInterfaceSnapshot]
    let publicIP: Availability<String>
    let hotspotProxy: HotspotProxyStatus
    let powerAssertions: [PowerAssertionRow]
    let processes: [ProcessRow]
    let containers: ContainerRuntimeStatus
    let launchAgents: LaunchAgentStatus
}

typealias ProcessDetailSnapshot = ProcessRow
typealias PowerAssertionSnapshot = PowerAssertionRow
enum DashboardFormat {
    static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", min(100, max(0, value)))
    }

    static func processPercent(_ value: Double) -> String {
        String(format: "%.1f%%", max(0, value))
    }

    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .binary)
    }

    static func rate(_ value: Double) -> String {
        "\(bytes(UInt64(max(0, value))))/s"
    }

    static func rate(_ value: UInt64) -> String {
        "\(bytes(value))/s"
    }

    static func bitRate(_ value: UInt64) -> String {
        let units = ["bps", "Kbps", "Mbps", "Gbps", "Tbps"]
        var scaled = Double(value)
        var index = 0
        while scaled >= 1_000, index < units.count - 1 {
            scaled /= 1_000
            index += 1
        }
        return String(format: scaled >= 100 || index == 0 ? "%.0f %@" : "%.1f %@", scaled, units[index])
    }
    /// A home-relative path keeps the meaningful tail of a project directory
    /// visible in a narrow column instead of spending it on /Users/<name>.
    static func homeRelativePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard !home.isEmpty else { return path }
        if path == home { return "~" }
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    static func address(_ address: String, port: UInt16) -> String {
        address.contains(":") ? "[\(address)]:\(port)" : "\(address):\(port)"
    }

    static func text<Value: Equatable>(_ availability: Availability<Value>, formatter: (Value) -> String) -> String {
        switch availability {
        case let .available(value): return formatter(value)
        case .unavailable: return "N/A"
        case .unknown: return "Unknown"
        }
    }
}
