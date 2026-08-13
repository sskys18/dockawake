import AppKit

final class StatusStripView {
    private static let fixedSymbols = [
        ("cpu", "CPU usage"),
        ("memorychip", "Memory usage"),
        ("internaldrive", "Storage usage")
    ]
    private var batterySymbol = ("battery.50percent", "Battery charge")
    private var symbols: [(String, String)] { Self.fixedSymbols + [batterySymbol] }
    private var values = ["N/A", "N/A", "N/A", "N/A"]

    var attributedTitle: NSAttributedString {
        let output = NSMutableAttributedString()
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ]
        for (index, symbol) in symbols.enumerated() {
            if index > 0 {
                output.append(NSAttributedString(string: "  ", attributes: textAttributes))
            }
            let attachment = NSTextAttachment()
            attachment.image = NSImage(systemSymbolName: symbol.0, accessibilityDescription: symbol.1)
            output.append(NSAttributedString(attachment: attachment))
            output.append(NSAttributedString(string: " \(values[index])", attributes: textAttributes))
        }
        return output
    }

    /// Names each metric next to its value, so the tooltip and VoiceOver can
    /// explain what the four icons mean.
    var labeledSummary: String {
        zip(symbols, values)
            .map { symbol, value in "\(symbol.1): \(value)" }
            .joined(separator: "\n")
    }
    func update(with snapshot: SystemSummarySnapshot) {
        precondition(Thread.isMainThread)
        let metrics = [snapshot.cpu, snapshot.memory, snapshot.storage, snapshot.battery]
        values = metrics.map { metric in
            switch metric {
            case let .available(value): return value.text
            case .unavailable, .unknown: return "N/A"
            }
        }
        batterySymbol = Self.batterySymbol(
            percent: snapshot.battery.value?.value,
            power: snapshot.batteryPower.value)
    }

    /// The icon carries the charger state, which the percentage alone cannot
    /// show because it stays put for minutes after plugging in.
    private static func batterySymbol(percent: Double?, power: BatteryPower?) -> (String, String) {
        let level: String
        switch percent {
        case .some(let value) where value >= 87.5: level = "battery.100percent"
        case .some(let value) where value >= 62.5: level = "battery.75percent"
        case .some(let value) where value >= 37.5: level = "battery.50percent"
        case .some(let value) where value >= 12.5: level = "battery.25percent"
        case .some: level = "battery.0percent"
        case .none: level = "battery.50percent"
        }
        switch power {
        case .charging: return ("battery.100percent.bolt", "Battery charge, charging")
        case .pluggedNotCharging: return ("powerplug", "Battery charge, plugged in")
        case .onBattery: return (level, "Battery charge, on battery")
        case .none: return (level, "Battery charge")
        }
    }
}
