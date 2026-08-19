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

    init(value: Double, text: String) {
        self.value = value
        self.text = text
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
    let cpuPercent: Availability<Double>
    let memoryBytes: Availability<UInt64>
    let energyProxyPercent: Availability<Double>
    let ports: Availability<[ListeningPort]>
    let missingRefreshCount: Int

    var isRetainedMissing: Bool { missingRefreshCount > 0 }
    var cpuText: String { DashboardFormat.text(cpuPercent, formatter: DashboardFormat.processPercent) }
    var memoryText: String { DashboardFormat.text(memoryBytes, formatter: DashboardFormat.bytes) }
    var energyProxyText: String { DashboardFormat.text(energyProxyPercent, formatter: DashboardFormat.percent) }
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

    var stateText: String {
        if isInvalid { return "Invalid" }
        if isRunning { return "Running" }
        return isLoaded ? "Loaded" : "Not loaded"
    }

    var pidText: String { pid.map(String.init) ?? "-" }
    var programText: String { program.isEmpty ? "N/A" : program }

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

struct DetailSnapshot: Equatable {
    let generation: UInt64
    let timestamp: Date
    let interfaces: [NetworkInterfaceSnapshot]
    let publicIP: Availability<String>
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
