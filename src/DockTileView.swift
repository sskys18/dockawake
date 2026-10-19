import AppKit

/// Live Dock icon: four ring gauges (CPU, memory, storage, battery) on a dark
/// squircle. The Dock tile is the app's only always-visible surface.
final class DockTileView: NSView {
    private struct Gauge {
        let label: String
        var fraction: Double?
        var text: String
        /// Battery reads "good" when high, the rest read "good" when low.
        let highIsGood: Bool
    }

    private var gauges = [
        Gauge(label: "CPU", fraction: nil, text: "–", highIsGood: false),
        Gauge(label: "MEM", fraction: nil, text: "–", highIsGood: false),
        Gauge(label: "SSD", fraction: nil, text: "–", highIsGood: false),
        Gauge(label: "BAT", fraction: nil, text: "–", highIsGood: true)
    ]
    private var power: BatteryPower?

    func update(with snapshot: SystemSummarySnapshot) {
        precondition(Thread.isMainThread)
        let metrics = [snapshot.cpu, snapshot.memory, snapshot.storage, snapshot.battery]
        for (index, metric) in metrics.enumerated() {
            if let value = metric.value?.value {
                gauges[index].fraction = min(max(value / 100, 0), 1)
                gauges[index].text = "\(Int(value.rounded()))"
            } else {
                gauges[index].fraction = nil
                gauges[index].text = "–"
            }
        }
        power = snapshot.batteryPower.value
        needsDisplay = true
    }

    /// Label and value per gauge as drawn, e.g. "CPU 10".
    var renderedGauges: [String] {
        gauges.indices.map { "\(label(at: $0)) \(gauges[$0].text)" }
    }

    private func label(at index: Int) -> String {
        guard index == 3 else { return gauges[index].label }
        switch power {
        case .charging: return "⚡︎BAT"
        case .pluggedNotCharging: return "AC"
        case .onBattery, .none: return gauges[index].label
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let side = min(bounds.width, bounds.height)
        let inset = side * 0.06
        let tile = NSRect(
            x: bounds.midX - side / 2 + inset,
            y: bounds.midY - side / 2 + inset,
            width: side - inset * 2,
            height: side - inset * 2)

        // Background squircle.
        let background = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
        NSGradient(colors: [
            NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.21, alpha: 1),
            NSColor(calibratedRed: 0.06, green: 0.06, blue: 0.09, alpha: 1)
        ])?.draw(in: background, angle: -90)
        NSColor.white.withAlphaComponent(0.12).setStroke()
        background.lineWidth = max(1, side / 128)
        background.stroke()

        // 2x2 gauge grid.
        let padding = tile.width * 0.07
        let cellSide = (tile.width - padding * 3) / 2
        for (index, gauge) in gauges.enumerated() {
            let column = CGFloat(index % 2)
            let row = CGFloat(1 - index / 2)
            let cell = NSRect(
                x: tile.minX + padding + column * (cellSide + padding),
                y: tile.minY + padding + row * (cellSide + padding),
                width: cellSide,
                height: cellSide)
            draw(gauge, label: label(at: index), in: cell)
        }
    }

    private func draw(_ gauge: Gauge, label labelText: String, in cell: NSRect) {
        let lineWidth = cell.width * 0.11
        let radius = (cell.width - lineWidth) / 2
        let center = NSPoint(x: cell.midX, y: cell.midY)

        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = lineWidth
        NSColor.white.withAlphaComponent(0.1).setStroke()
        track.stroke()

        if let fraction = gauge.fraction, fraction > 0 {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true)
            arc.lineWidth = lineWidth
            arc.lineCapStyle = .round
            Self.color(for: fraction, highIsGood: gauge.highIsGood).setStroke()
            arc.stroke()
        }

        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: cell.width * 0.3, weight: .bold)
        let labelFont = NSFont.systemFont(ofSize: cell.width * 0.15, weight: .semibold)
        let value = NSAttributedString(string: gauge.text, attributes: [
            .font: valueFont,
            .foregroundColor: NSColor.white
        ])
        let label = NSAttributedString(string: labelText, attributes: [
            .font: labelFont,
            .foregroundColor: NSColor.white.withAlphaComponent(0.6),
            .kern: cell.width * 0.01
        ])
        let valueSize = value.size()
        let labelSize = label.size()
        let total = valueSize.height + labelSize.height * 0.8
        let top = center.y + total / 2
        value.draw(at: NSPoint(x: center.x - valueSize.width / 2, y: top - valueSize.height))
        label.draw(at: NSPoint(x: center.x - labelSize.width / 2, y: top - valueSize.height - labelSize.height * 0.85))
    }

    private static func color(for fraction: Double, highIsGood: Bool) -> NSColor {
        let load = highIsGood ? 1 - fraction : fraction
        switch load {
        case ..<0.6: return NSColor(calibratedRed: 0.27, green: 0.85, blue: 0.55, alpha: 1)
        case ..<0.85: return NSColor(calibratedRed: 1.0, green: 0.74, blue: 0.2, alpha: 1)
        default: return NSColor(calibratedRed: 1.0, green: 0.33, blue: 0.33, alpha: 1)
        }
    }
}
