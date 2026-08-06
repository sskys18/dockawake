import Darwin
import Foundation

final class ProcessCollector {
    private struct Sample {
        let name: String
        let totalCPUTime: UInt64?
        let memoryBytes: UInt64?
    }
    private struct StoredRow {
        var row: ProcessRow
        var totalCPUTime: UInt64?
        var sampledAt: TimeInterval
    }

    static let minimumSampleInterval: TimeInterval = 0.25

    private let runner: CommandRunning
    private var rows: [ProcessIdentity: StoredRow] = [:]
    private let processorCount = max(1, ProcessInfo.processInfo.activeProcessorCount)
    /// libproc reports task times in mach time units, which are not nanoseconds
    /// on Apple silicon, so every delta needs the host timebase ratio applied.
    private let machTicksToNanoseconds: Double = {
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom != 0 else { return 1 }
        return Double(timebase.numer) / Double(timebase.denom)
    }()

    init(runner: CommandRunning = CommandRunner()) { self.runner = runner }

    func reset() { rows.removeAll() }
    func cancelActiveCollection() {
        (runner as? CommandCancelling)?.cancelActiveCommand()
    }

    func collect() -> [ProcessRow] {
        let now = ProcessInfo.processInfo.systemUptime
        let identities = enumerateIdentities()
        let identitySet = Set(identities)
        var next: [ProcessIdentity: StoredRow] = [:]

        for identity in identities {
            // A PID is never allowed to carry a prior incarnation's baseline or ports.
            let obsoleteIdentities = rows.keys.filter {
                $0.pid == identity.pid && $0 != identity
            }
            for oldIdentity in obsoleteIdentities {
                rows.removeValue(forKey: oldIdentity)
            }
            let prior = rows[identity]
            let sample = sample(for: identity.pid)
            guard let confirmedIdentity = self.identity(for: identity.pid) else {
                let row = ProcessRow(
                    id: identity,
                    name: prior?.row.name ?? "Unknown",
                    cpuPercent: .unavailable,
                    memoryBytes: .unavailable,
                    energyProxyPercent: .unavailable,
                    ports: .unavailable,
                    missingRefreshCount: 0)
                next[identity] = StoredRow(row: row, totalCPUTime: nil, sampledAt: now)
                continue
            }
            guard confirmedIdentity == identity else { continue }
            let cpu: Availability<Double>
            // Too short a window turns rounding noise into headline percentages,
            // so a delta is only reported once it covers a measurable interval.
            if let total = sample.totalCPUTime, let priorTotal = prior?.totalCPUTime,
               now - prior!.sampledAt >= Self.minimumSampleInterval, total >= priorTotal {
                let nanoseconds = Double(total - priorTotal) * machTicksToNanoseconds
                cpu = .available(nanoseconds / (now - prior!.sampledAt) / 10_000_000)
            } else {
                cpu = .unavailable
            }
            let memory = sample.memoryBytes.map(Availability.available) ?? .unavailable
            let energy: Availability<Double>
            if case let .available(value) = cpu {
                energy = .available(min(100, max(0, value / Double(processorCount))))
            } else { energy = .unavailable }
            let row = ProcessRow(id: identity, name: sample.name, cpuPercent: cpu, memoryBytes: memory, energyProxyPercent: energy, ports: .unavailable, missingRefreshCount: 0)
            next[identity] = StoredRow(row: row, totalCPUTime: sample.totalCPUTime, sampledAt: now)
        }

        for (identity, stored) in rows where !identitySet.contains(identity) {
            guard stored.row.missingRefreshCount == 0 else { continue }
            let retained = ProcessRow(id: identity, name: stored.row.name, cpuPercent: .unavailable, memoryBytes: .unavailable, energyProxyPercent: .unavailable, ports: .unavailable, missingRefreshCount: 1)
            next[identity] = StoredRow(row: retained, totalCPUTime: nil, sampledAt: now)
        }
        rows = next
        mergePorts(readListeningPorts(), into: identitySet)
        return rows.values.map(\.row).sorted { $0.id < $1.id }
    }

    private func enumerateIdentities() -> [ProcessIdentity] {
        let byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard byteCount > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(byteCount) / MemoryLayout<pid_t>.size)
        let written = pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0.baseAddress, Int32($0.count)) }
        guard written > 0 else { return [] }
        return pids.prefix(Int(written) / MemoryLayout<pid_t>.size).compactMap { identity(for: $0) }
    }

    private func identity(for pid: pid_t) -> ProcessIdentity? {
        var info = proc_bsdinfo()
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard size == Int32(MemoryLayout<proc_bsdinfo>.size) else { return nil }
        return ProcessIdentity(pid: pid, startSeconds: Int64(info.pbi_start_tvsec), startMicroseconds: Int32(info.pbi_start_tvusec))
    }

    private func sample(for pid: pid_t) -> Sample {
        var task = proc_taskinfo()
        let size = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.size))
        // libproc rejects any buffer smaller than proc_bsdinfo.pbi_name, which is
        // 2 * MAXCOMLEN. A MAXCOMLEN buffer fails with ENOMEM for every process.
        var name = [CChar](repeating: 0, count: Int(2 * MAXCOMLEN) + 1)
        let nameLength = proc_name(pid, &name, UInt32(name.count))
        let command = nameLength > 0 ? String(cString: name) : "Unknown"
        let cpuTime: UInt64? = size == Int32(MemoryLayout<proc_taskinfo>.size)
            ? task.pti_total_user + task.pti_total_system
            : nil
        var usage = rusage_info_v4()
        let usageResult = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        let memory = usageResult == 0 ? usage.ri_phys_footprint : nil
        return Sample(name: command, totalCPUTime: cpuTime, memoryBytes: memory)
    }

    private func readListeningPorts() -> [ProcessIdentity: [ListeningPort]]? {
        let result = runner.run(executable: "/usr/sbin/lsof", arguments: ["-nP", "-a", "-iTCP", "-sTCP:LISTEN", "-F0pcfPnT"], outputLimit: 1_048_576, timeout: 5)
        guard result.succeeded, let text = String(data: result.output, encoding: .utf8), text.isEmpty || text.hasSuffix("\n") else { return nil }
        var ports: [pid_t: [ListeningPort]] = [:]
        var pid: pid_t?
        var command = ""
        var fd: Int32?
        var proto: String?
        var address: String?
        var listening = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\0", omittingEmptySubsequences: true)
            guard !fields.isEmpty else { return nil }
            for field in fields {
                guard let tag = field.first else { return nil }
                let value = String(field.dropFirst())
                switch tag {
                case "p": guard let valuePID = pid_t(value) else { return nil }; pid = valuePID; command = ""; fd = nil; proto = nil; address = nil; listening = false
                case "c": command = value
                case "f": fd = Int32(value); proto = nil; address = nil; listening = false
                case "P": proto = value.lowercased()
                case "n": address = value
                case "T": if value == "ST=LISTEN" { listening = true }
                default: continue
                }
            }
            if listening, let processID = pid, let protocolName = proto, let endpoint = address, let port = parsePort(endpoint) {
                _ = command
                ports[processID, default: []].append(ListeningPort(protocolName: protocolName, address: endpointAddress(endpoint), port: port, fileDescriptor: fd))
            }
        }
        var verified: [ProcessIdentity: [ListeningPort]] = [:]
        for (processID, values) in ports {
            guard let identity = identity(for: processID) else { continue }
            verified[identity] = Array(Set(values)).sorted { $0.displayText < $1.displayText }
        }
        return verified
    }

    private func mergePorts(_ ports: [ProcessIdentity: [ListeningPort]]?, into visible: Set<ProcessIdentity>) {
        guard let ports else { return }
        for identity in visible {
            guard var stored = rows[identity] else { continue }
            let value = ports[identity] ?? []
            let old = stored.row
            stored.row = ProcessRow(id: old.id, name: old.name, cpuPercent: old.cpuPercent, memoryBytes: old.memoryBytes, energyProxyPercent: old.energyProxyPercent, ports: .available(value), missingRefreshCount: old.missingRefreshCount)
            rows[identity] = stored
        }
    }

    private func parsePort(_ endpoint: String) -> UInt16? {
        let suffix = endpoint.split(separator: ":").last ?? ""
        return UInt16(suffix)
    }

    private func endpointAddress(_ endpoint: String) -> String {
        guard let colon = endpoint.lastIndex(of: ":") else { return endpoint }
        return String(endpoint[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }
}
