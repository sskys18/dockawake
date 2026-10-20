import AppKit
import Charts
import SwiftUI

enum DashboardSection: Int, CaseIterable {
    case overview, processes, containers, launchAgents

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .processes: return "Processes"
        case .containers: return "Containers"
        case .launchAgents: return "Launch Agents"
        }
    }
}

/// Everything the Overview draws. Summary history keeps filling while the
/// window is closed so the charts are already populated when it opens; detail
/// data and network history exist only for an open window.
final class OverviewModel: ObservableObject {
    /// Ten minutes of the five-second summary cadence.
    static let historyCapacity = 120

    @Published private(set) var summary: SystemSummarySnapshot?
    @Published private(set) var cpuHistory = BoundedHistory(capacity: historyCapacity)
    @Published private(set) var memoryHistory = BoundedHistory(capacity: historyCapacity)
    @Published private(set) var receivedHistory = BoundedHistory(capacity: historyCapacity)
    @Published private(set) var sentHistory = BoundedHistory(capacity: historyCapacity)
    @Published private(set) var keepAwake: KeepAwakeUIState?
    @Published private(set) var detail: DetailSnapshot?

    var onNavigate: ((DashboardSection) -> Void)?

    func update(summary snapshot: SystemSummarySnapshot) {
        summary = snapshot
        if let cpu = snapshot.cpu.value?.value {
            cpuHistory.append(HistorySample(date: snapshot.timestamp, value: cpu))
        }
        if let memory = snapshot.memory.value?.value {
            memoryHistory.append(HistorySample(date: snapshot.timestamp, value: memory))
        }
    }

    func update(keepAwake state: KeepAwakeUIState) {
        keepAwake = state
    }

    func update(detail snapshot: DetailSnapshot) {
        detail = snapshot
        // The first pass has no prior counter sample, so it carries no rates and
        // is left out rather than charted as a zero.
        guard let throughput = NetworkThroughput.aggregate(snapshot.interfaces),
              snapshot.interfaces.contains(where: { $0.receivedRateBytesPerSecond.value != nil }) else { return }
        receivedHistory.append(HistorySample(date: snapshot.timestamp, value: throughput.receivedBytesPerSecond))
        sentHistory.append(HistorySample(date: snapshot.timestamp, value: throughput.sentBytesPerSecond))
    }

    func clearDetail() {
        detail = nil
        receivedHistory.removeAll()
        sentHistory.removeAll()
    }
}

struct OverviewView: View {
    @ObservedObject var model: OverviewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                gaugeRow
                equalHeight(260) {
                    LoadHistoryCard(cpu: model.cpuHistory.samples, memory: model.memoryHistory.samples)
                        .frame(maxWidth: .infinity)
                    NetworkCard(
                        detail: model.detail,
                        received: model.receivedHistory.samples,
                        sent: model.sentHistory.samples)
                        .frame(width: 380)
                }
                equalHeight(304) {
                    TopConsumersCard(
                        title: "Top CPU",
                        icon: "cpu",
                        rows: model.detail.map { TopConsumers.byCPU($0.processes, limit: 6) },
                        value: { $0.cpuPercent.value ?? 0 },
                        text: \.cpuText,
                        color: Self.cpuColor,
                        onShowAll: { model.onNavigate?(.processes) })
                    TopConsumersCard(
                        title: "Top Memory",
                        icon: "memorychip",
                        rows: model.detail.map { TopConsumers.byMemory($0.processes, limit: 6) },
                        value: { Double($0.memoryBytes.value ?? 0) },
                        text: \.memoryText,
                        color: Self.memoryColor,
                        onShowAll: { model.onNavigate?(.processes) })
                }
                equalHeight(260) {
                    AwakeCard(keepAwake: model.keepAwake, detail: model.detail)
                        .frame(maxWidth: .infinity)
                    ContainersCard(status: model.detail?.containers, onOpen: { model.onNavigate?(.containers) })
                        .frame(width: 300)
                    LaunchAgentsCard(status: model.detail?.launchAgents, onOpen: { model.onNavigate?(.launchAgents) })
                        .frame(width: 300)
                }
            }
            .padding(18)
        }
    }

    private var gaugeRow: some View {
        let summary = model.summary
        return equalHeight {
            GaugeCard(title: "CPU", icon: "cpu", metric: summary?.cpu ?? .unknown,
                      highIsGood: false, history: model.cpuHistory.samples)
            GaugeCard(title: "Memory", icon: "memorychip", metric: summary?.memory ?? .unknown,
                      highIsGood: false, history: model.memoryHistory.samples)
            GaugeCard(title: "Storage", icon: "internaldrive", metric: summary?.storage ?? .unknown,
                      highIsGood: false, history: nil)
            GaugeCard(title: "Battery", icon: Self.batteryIcon(summary), metric: summary?.battery ?? .unknown,
                      highIsGood: true, history: nil, footnote: summary?.batteryPower.value?.text)
        }
    }

    /// Cards in one row stretch to the tallest so their edges line up. Rows
    /// whose content arrives later get a fixed height, so loading never shifts
    /// the layout or the scroll position.
    @ViewBuilder
    private func equalHeight<Content: View>(_ height: CGFloat? = nil, @ViewBuilder _ content: () -> Content) -> some View {
        let row = HStack(alignment: .top, spacing: 14) { content() }
        if let height {
            row.frame(height: height)
        } else {
            row.fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func batteryIcon(_ summary: SystemSummarySnapshot?) -> String {
        switch summary?.batteryPower.value {
        case .charging: return "battery.100.bolt"
        case .pluggedNotCharging: return "powerplug"
        case .onBattery, .none: return "battery.75"
        }
    }

    /// Same absolute thresholds as the Processes table.
    private static func cpuColor(_ row: ProcessRow) -> Color {
        let cpu = row.cpuPercent.value ?? 0
        if cpu >= 100 { return Color(nsColor: LoadPalette.red) }
        if cpu >= 50 { return Color(nsColor: LoadPalette.amber) }
        return .accentColor
    }

    private static func memoryColor(_ row: ProcessRow) -> Color {
        let bytes = row.memoryBytes.value ?? 0
        if bytes >= 4 * 1024 * 1024 * 1024 { return Color(nsColor: LoadPalette.red) }
        if bytes >= 1024 * 1024 * 1024 { return Color(nsColor: LoadPalette.amber) }
        return .purple
    }
}

// MARK: - Building blocks

private struct Card<Accessory: View, Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let accessory: Accessory
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                accessory
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
    }
}

extension Card where Accessory == EmptyView {
    init(title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.accessory = EmptyView()
        self.content = content()
    }
}

/// A plain text button that jumps to a detail section.
private struct OpenButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Text(title)
                Image(systemName: "chevron.right")
            }
            .font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
    }
}

/// Explains why a detail card is empty instead of drawing fake zeros.
private struct Placeholder: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 60)
    }
}

private struct Ring: View {
    let fraction: Double?
    let color: Color
    var lineWidth: CGFloat = 9

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: lineWidth)
            if let fraction {
                Circle()
                    .trim(from: 0, to: max(0.004, min(1, fraction)))
                    .stroke(
                        AngularGradient(colors: [color.opacity(0.55), color], center: .center,
                                        startAngle: .degrees(0), endAngle: .degrees(360 * max(0.01, fraction))),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .animation(.easeOut(duration: 0.6), value: fraction)
    }
}

private struct GaugeCard: View {
    let title: String
    let icon: String
    let metric: Availability<MetricDisplay>
    let highIsGood: Bool
    let history: [HistorySample]?
    var footnote: String?

    private var fraction: Double? { metric.value.map { min(max($0.value / 100, 0), 1) } }
    private var color: Color {
        guard let fraction else { return .secondary }
        return Color(nsColor: LoadPalette.color(for: fraction, highIsGood: highIsGood))
    }

    var body: some View {
        Card(title: title, icon: icon) {
            HStack(spacing: 14) {
                Ring(fraction: fraction, color: color)
                    .frame(width: 58, height: 58)
                VStack(alignment: .leading, spacing: 3) {
                    Text(valueText)
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(fraction == nil ? .secondary : .primary)
                    Text(metric.value?.detail ?? " ")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let footnote {
                        Text(footnote)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(color)
                    }
                }
                Spacer(minLength: 0)
            }
            if let history {
                Sparkline(samples: history, color: color)
                    .frame(height: 34)
            }
        }
    }

    private var valueText: String {
        switch metric {
        case let .available(display): return "\(Int(display.value.rounded()))%"
        case .unavailable: return "N/A"
        case .unknown: return "…"
        }
    }
}

private struct Sparkline: View {
    let samples: [HistorySample]
    let color: Color

    var body: some View {
        if samples.count < 2 {
            Text("Collecting…")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Chart(samples) { sample in
                AreaMark(x: .value("Time", sample.date), y: .value("Value", sample.value))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Time", sample.date), y: .value("Value", sample.value))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            .chartYScale(domain: 0...100)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
        }
    }
}

private struct LoadHistoryCard: View {
    let cpu: [HistorySample]
    let memory: [HistorySample]

    private struct Point: Identifiable {
        let series: String
        let sample: HistorySample
        var id: String { "\(series)-\(sample.date.timeIntervalSince1970)" }
    }

    var body: some View {
        Card(title: "Load · last 10 minutes", icon: "waveform.path.ecg") {
            HStack(spacing: 14) {
                legend("CPU", .accentColor)
                legend("Memory", .purple)
            }
        } content: {
            if cpu.count < 2 && memory.count < 2 {
                Placeholder(text: "Collecting samples every 5 seconds…")
                    .frame(maxHeight: .infinity)
            } else {
                Chart {
                    ForEach(cpu) { sample in
                        AreaMark(x: .value("Time", sample.date),
                                 yStart: .value("Percent", 0),
                                 yEnd: .value("Percent", sample.value),
                                 series: .value("Series", "CPU area"))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(LinearGradient(colors: [Color.accentColor.opacity(0.3), Color.accentColor.opacity(0.02)],
                                                            startPoint: .top, endPoint: .bottom))
                    }
                    ForEach(points) { point in
                        LineMark(x: .value("Time", point.sample.date),
                                 y: .value("Percent", point.sample.value),
                                 series: .value("Series", point.series))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(point.series == "CPU" ? Color.accentColor : Color.purple)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                }
                .chartYScale(domain: 0...100)
                .chartYAxis {
                    AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                        AxisGridLine()
                        AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%") }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.hour().minute())
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    private var points: [Point] {
        cpu.map { Point(series: "CPU", sample: $0) } + memory.map { Point(series: "Memory", sample: $0) }
    }

    private func legend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct NetworkCard: View {
    let detail: DetailSnapshot?
    let received: [HistorySample]
    let sent: [HistorySample]

    private static let downColor = Color(nsColor: LoadPalette.green)
    private static let upColor = Color.blue

    private struct Point: Identifiable {
        let series: String
        let sample: HistorySample
        var id: String { "\(series)-\(sample.date.timeIntervalSince1970)" }
    }

    var body: some View {
        Card(title: "Network", icon: "network") {
            Text(publicIPText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .help("Public IP from api.ipify.org")
        } content: {
            if let detail {
                let throughput = NetworkThroughput.aggregate(detail.interfaces)
                HStack(spacing: 18) {
                    rate("arrow.down", throughput.map { DashboardFormat.rate($0.receivedBytesPerSecond) } ?? "N/A", Self.downColor)
                    rate("arrow.up", throughput.map { DashboardFormat.rate($0.sentBytesPerSecond) } ?? "N/A", Self.upColor)
                }
                chart
                    .frame(height: 70)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Self.routableInterfaces(detail.interfaces).prefix(3), id: \.interface.name) { entry in
                        let interface = entry.interface
                        HStack(spacing: 6) {
                            Text(interface.name)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .frame(width: 52, alignment: .leading)
                            Text(entry.address)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            Spacer(minLength: 4)
                            if interface.linkSpeedBitsPerSecond.value != nil {
                                Text(interface.linkSpeedText)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            } else {
                Placeholder(text: "Loading live network data…")
            }
        }
    }

    @ViewBuilder private var chart: some View {
        if received.count < 2 {
            Text("Collecting…")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Chart(received.map { Point(series: "Down", sample: $0) } + sent.map { Point(series: "Up", sample: $0) }) { point in
                let color = point.series == "Down" ? Self.downColor : Self.upColor
                AreaMark(x: .value("Time", point.sample.date),
                         yStart: .value("Rate", 0),
                         yEnd: .value("Rate", point.sample.value),
                         series: .value("Series", point.series))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(color.opacity(0.22))
                LineMark(x: .value("Time", point.sample.date),
                         y: .value("Rate", point.sample.value),
                         series: .value("Series", point.series))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        let rate = value.as(Double.self) ?? 0
                        Text(rate > 0 ? DashboardFormat.rate(rate) : "0").font(.system(size: 9))
                    }
                }
            }
        }
    }

    /// Link-local IPv6 addresses (fe80::) exist on every virtual interface and
    /// say nothing about how the Mac is connected, so the card lists only
    /// interfaces with an address another machine could reach.
    private static func routableInterfaces(_ interfaces: [NetworkInterfaceSnapshot]) -> [(interface: NetworkInterfaceSnapshot, address: String)] {
        NetworkThroughput.activeInterfaces(interfaces).compactMap { interface in
            let routable = interface.addresses.filter { !$0.lowercased().hasPrefix("fe80:") }
            guard let address = routable.first(where: { !$0.contains(":") }) ?? routable.first else { return nil }
            return (interface, address)
        }
    }

    private var publicIPText: String {
        switch detail?.publicIP {
        case let .available(address): return address
        case .unavailable: return "Public IP unavailable"
        case .unknown, .none: return "Checking public IP…"
        }
    }

    private func rate(_ icon: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(color)
            Text(text)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
    }
}

private struct TopConsumersCard: View {
    let title: String
    let icon: String
    let rows: [ProcessRow]?
    let value: (ProcessRow) -> Double
    let text: KeyPath<ProcessRow, String>
    let color: (ProcessRow) -> Color
    let onShowAll: () -> Void

    var body: some View {
        Card(title: title, icon: icon) {
            OpenButton(title: "All processes", action: onShowAll)
        } content: {
            if let rows {
                if rows.isEmpty {
                    Placeholder(text: "Nothing measurable yet")
                } else {
                    let maximum = rows.map(value).max() ?? 1
                    VStack(spacing: 9) {
                        ForEach(rows) { row in
                            bar(row, fraction: maximum > 0 ? value(row) / maximum : 0)
                        }
                    }
                }
            } else {
                Placeholder(text: "Loading processes…")
            }
        }
    }

    private func bar(_ row: ProcessRow, fraction: Double) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                // The pid tells apart two sessions of one CLI in the same project,
                // so it never truncates; a long directory loses its head instead.
                HStack(spacing: 4) {
                    Text(verbatim: String(row.id.pid))
                        .fixedSize()
                    Text(verbatim: row.directory.value.map(DashboardFormat.homeRelativePath) ?? "N/A")
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.tertiary)
            }
            .frame(width: 170, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.06))
                    Capsule()
                        .fill(LinearGradient(colors: [color(row).opacity(0.65), color(row)],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(6, proxy.size.width * fraction))
                }
            }
            .frame(height: 10)
            .animation(.easeOut(duration: 0.5), value: fraction)
            Text(row[keyPath: text])
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .frame(width: 72, alignment: .trailing)
        }
        .help("pid \(row.id.pid) · \(row.commandText)")
    }
}

private struct AwakeCard: View {
    let keepAwake: KeepAwakeUIState?
    let detail: DetailSnapshot?

    /// One line per owner: a single app often holds many identical assertions,
    /// and thirty rows of the same name hide everyone else.
    private struct Holder: Identifiable {
        let name: String
        let types: [String]
        let reason: String
        let count: Int
        var id: String { name }
    }

    private var isOn: Bool { keepAwake?.current.value == true }

    var body: some View {
        Card(title: "Sleep", icon: "moon.zzz") {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(isOn ? Color(nsColor: LoadPalette.amber) : Color.primary.opacity(0.08))
                        .shadow(color: isOn ? Color(nsColor: LoadPalette.amber).opacity(0.6) : .clear, radius: 10)
                    Image(systemName: isOn ? "cup.and.saucer.fill" : "moon.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(isOn ? Color.black.opacity(0.8) : Color.secondary)
                }
                .frame(width: 48, height: 48)
                .animation(.easeOut(duration: 0.3), value: isOn)
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline)
                        .font(.system(size: 16, weight: .semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(keepAwake?.helperError == nil ? .secondary : Color(nsColor: LoadPalette.red))
                        .lineLimit(2)
                }
            }
            Divider()
            holderList
        }
    }

    private var headline: String {
        if let pending = keepAwake?.pendingIntent {
            return pending ? "Turning Keep Awake on…" : "Turning Keep Awake off…"
        }
        switch keepAwake?.current {
        case .available(true): return "Kept awake, even with the lid closed"
        case .available(false): return "Sleeps normally"
        case .unavailable: return "Sleep state unavailable"
        case .unknown, .none: return "Reading sleep state…"
        }
    }

    private var subtitle: String {
        if let error = keepAwake?.helperError { return error }
        return "Toggle Keep Awake at the top right. Quitting DockAwake always restores normal sleep."
    }

    private var holders: [Holder] {
        guard let detail else { return [] }
        let names = Dictionary(detail.processes.map { ($0.id.pid, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        let grouped = Dictionary(grouping: detail.powerAssertions) { assertion -> String in
            if let name = assertion.ownerName { return name }
            if let pid = assertion.ownerPID { return names[pid] ?? "pid \(pid)" }
            return "Unknown owner"
        }
        return grouped.map { name, rows in
            Holder(
                name: name,
                types: Array(Set(rows.map(\.type))).sorted(),
                reason: rows.compactMap(\.reason).first ?? "",
                count: rows.count)
        }
        .sorted { $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count }
    }

    @ViewBuilder private var holderList: some View {
        if let detail {
            let holders = holders
            Text(detail.powerAssertions.isEmpty
                 ? "No app is holding off sleep"
                 : "Holding off sleep · \(holders.count) apps, \(detail.powerAssertions.count) assertions")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(holders.prefix(4)) { holder in
                    HStack(spacing: 8) {
                        Text(holder.name)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        if holder.count > 1 {
                            Text("×\(holder.count)")
                                .font(.system(size: 11, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        ForEach(holder.types, id: \.self) { type in
                            Text(type)
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color(nsColor: LoadPalette.amber).opacity(0.18)))
                                .foregroundStyle(Color(nsColor: LoadPalette.amber))
                                .lineLimit(1)
                        }
                        Text(holder.reason)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .help(holder.reason)
                }
            }
        } else {
            Text("Loading power assertions…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct BigStat: View {
    let value: String
    let caption: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ContainersCard: View {
    let status: ContainerRuntimeStatus?
    let onOpen: () -> Void

    var body: some View {
        Card(title: "Containers", icon: "shippingbox") {
            OpenButton(title: "Open", action: onOpen)
        } content: {
            switch status {
            case .none:
                Placeholder(text: "Loading containers…")
            case .missingCLI, .daemonUnreachable:
                Placeholder(text: status?.summaryText ?? "")
            case let .available(rows):
                let running = rows.filter(\.isRunning)
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    BigStat(value: "\(running.count)", caption: "running",
                            color: running.isEmpty ? .secondary : Color(nsColor: LoadPalette.green))
                    BigStat(value: "\(rows.count - running.count)", caption: "stopped", color: .secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(running.prefix(4)) { row in
                        HStack(spacing: 6) {
                            Circle().fill(Color(nsColor: LoadPalette.green)).frame(width: 6, height: 6)
                            Text(row.displayName)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
    }
}

private struct LaunchAgentsCard: View {
    let status: LaunchAgentStatus?
    let onOpen: () -> Void

    var body: some View {
        Card(title: "Launch Agents", icon: "gearshape.2") {
            OpenButton(title: "Open", action: onOpen)
        } content: {
            switch status {
            case .none:
                Placeholder(text: "Loading launch agents…")
            case .directoryUnreadable, .runtimeUnreadable:
                Placeholder(text: status?.summaryText ?? "")
            case let .available(rows):
                let failed = rows.filter(\.failedLastRun)
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    BigStat(value: "\(rows.filter(\.isRunning).count)", caption: "running",
                            color: Color(nsColor: LoadPalette.green))
                    BigStat(value: "\(rows.filter(\.isLoaded).count)", caption: "loaded", color: .primary)
                    BigStat(value: "\(failed.count)", caption: "failed",
                            color: failed.isEmpty ? .secondary : Color(nsColor: LoadPalette.red))
                }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(failed.prefix(3)) { row in
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Color(nsColor: LoadPalette.red))
                            Text(row.labelText)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text("exit \(row.lastExitText)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}
