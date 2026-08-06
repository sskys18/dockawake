import AppKit

final class StatusStripView {
    private let symbols = [
        ("cpu", "CPU usage"),
        ("memorychip", "Memory usage"),
        ("internaldrive", "Storage usage"),
        ("battery.100percent.bolt", "Battery charge")
    ]
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
    }
}
