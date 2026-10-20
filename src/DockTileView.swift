import AppKit

/// Decides when the Dock icon should demand attention. Pure so it can be tested.
struct DockAlertTracker {
    static let cpuThreshold = 90.0
    static let cpuSustainedSamples = 3
    static let storageThreshold = 90.0
    static let batteryThreshold = 15.0

    private var hotCPUSamples = 0
    private(set) var badge: String?

    /// Returns true only when the alert state turns on, so the caller bounces once.
    mutating func update(with snapshot: SystemSummarySnapshot) -> Bool {
        if let cpu = snapshot.cpu.value?.value, cpu >= Self.cpuThreshold {
            hotCPUSamples += 1
        } else {
            hotCPUSamples = 0
        }
        var reasons: [String] = []
        if hotCPUSamples >= Self.cpuSustainedSamples { reasons.append("CPU") }
        if let storage = snapshot.storage.value?.value, storage >= Self.storageThreshold { reasons.append("SSD") }
        if let battery = snapshot.battery.value?.value, battery <= Self.batteryThreshold,
           snapshot.batteryPower.value == .onBattery {
            reasons.append("BAT")
        }
        let previous = badge
        badge = reasons.first
        return previous == nil && badge != nil
    }
}

/// Live Dock icon: a 2x2 grid of rings (CPU, memory / storage, battery),
/// with a keep-awake marker in the center. Values glide to each new sample.
final class DockTileView: NSView {
    private struct Metric {
        let label: String
        var target: Double?
        var shown: Double = 0
        var text = "–"
        /// Battery reads "good" when high, the rest read "good" when low.
        let highIsGood: Bool
    }

    private var metrics = [
        Metric(label: "CPU", highIsGood: false),
        Metric(label: "MEM", highIsGood: false),
        Metric(label: "SSD", highIsGood: false),
        Metric(label: "BAT", highIsGood: true)
    ]
    private var power: BatteryPower?
    private var animationTimer: Timer?

    /// Called after every redraw-worthy change; the Dock only repaints on request.
    var onNeedsDockRefresh: (() -> Void)?

    var keepAwake = false {
        didSet {
            guard keepAwake != oldValue else { return }
            onNeedsDockRefresh?()
        }
    }

    func update(with snapshot: SystemSummarySnapshot) {
        precondition(Thread.isMainThread)
        let values = [snapshot.cpu, snapshot.memory, snapshot.storage, snapshot.battery]
        for (index, metric) in values.enumerated() {
            if let value = metric.value?.value {
                metrics[index].target = min(max(value / 100, 0), 1)
                metrics[index].text = "\(Int(value.rounded()))"
            } else {
                metrics[index].target = nil
                metrics[index].text = "–"
            }
        }
        power = snapshot.batteryPower.value
        startAnimation()
    }

    /// Label and value per metric as drawn, e.g. "CPU 10".
    var renderedGauges: [String] {
        metrics.indices.map { "\(label(at: $0)) \(metrics[$0].text)" }
    }

    private func label(at index: Int) -> String {
        guard index == 3 else { return metrics[index].label }
        switch power {
        case .charging: return "⚡︎BAT"
        case .pluggedNotCharging: return "AC"
        case .onBattery, .none: return metrics[index].label
        }
    }

    private func startAnimation() {
        animationTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            var settled = true
            for index in self.metrics.indices {
                let target = self.metrics[index].target ?? 0
                let delta = target - self.metrics[index].shown
                if abs(delta) < 0.002 {
                    self.metrics[index].shown = target
                } else {
                    self.metrics[index].shown += delta * 0.2
                    settled = false
                }
            }
            self.onNeedsDockRefresh?()
            if settled {
                timer.invalidate()
                self.animationTimer = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    override func draw(_ dirtyRect: NSRect) {
        let side = min(bounds.width, bounds.height)
        let inset = side * 0.06
        let tile = NSRect(
            x: bounds.midX - side / 2 + inset,
            y: bounds.midY - side / 2 + inset,
            width: side - inset * 2,
            height: side - inset * 2)
        let unit = tile.width

        let background = NSBezierPath(roundedRect: tile, xRadius: unit * 0.225, yRadius: unit * 0.225)
        NSGradient(colors: [
            NSColor(calibratedRed: 0.17, green: 0.18, blue: 0.23, alpha: 1),
            NSColor(calibratedRed: 0.05, green: 0.05, blue: 0.08, alpha: 1)
        ])?.draw(in: background, angle: -90)
        NSColor.white.withAlphaComponent(0.12).setStroke()
        background.lineWidth = max(1, side / 128)
        background.stroke()

        // 2x2 grid, row-major from the top: CPU MEM / SSD BAT.
        let padding = unit * 0.06
        let cell = (unit - padding * 2) / 2
        let ringDiameter = cell * 0.92
        for index in metrics.indices {
            let column = CGFloat(index % 2)
            let row = CGFloat(index / 2)
            let cellCenter = NSPoint(
                x: tile.minX + padding + cell * (column + 0.5),
                y: tile.maxY - padding - cell * (row + 0.5))
            drawRing(metrics[index], label: label(at: index), in: NSRect(
                x: cellCenter.x - ringDiameter / 2,
                y: cellCenter.y - ringDiameter / 2,
                width: ringDiameter,
                height: ringDiameter))
        }

        if keepAwake {
            drawKeepAwakeMarker(in: tile)
        }
    }

    private func drawRing(_ metric: Metric, label labelText: String, in rect: NSRect) {
        let lineWidth = rect.width * 0.13
        let radius = (rect.width - lineWidth) / 2
        let center = NSPoint(x: rect.midX, y: rect.midY)

        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = lineWidth
        NSColor.white.withAlphaComponent(0.1).setStroke()
        track.stroke()

        if metric.target != nil, metric.shown > 0.005 {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: 90,
                          endAngle: 90 - 360 * metric.shown, clockwise: true)
            arc.lineWidth = lineWidth
            arc.lineCapStyle = .round
            LoadPalette.color(for: metric.shown, highIsGood: metric.highIsGood).setStroke()
            arc.stroke()
        }

        let value = NSAttributedString(string: metric.text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: rect.width * 0.32, weight: .heavy),
            .foregroundColor: NSColor.white
        ])
        let label = NSAttributedString(string: labelText, attributes: [
            .font: NSFont.systemFont(ofSize: rect.width * 0.16, weight: .bold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.55)
        ])
        let valueSize = value.size()
        let labelSize = label.size()
        let top = center.y + (valueSize.height + labelSize.height * 0.75) / 2
        value.draw(at: NSPoint(x: center.x - valueSize.width / 2, y: top - valueSize.height))
        label.draw(at: NSPoint(x: center.x - labelSize.width / 2, y: top - valueSize.height - labelSize.height * 0.8))
    }

    /// Amber cup in the gap between the four rings while sleep is disabled.
    private func drawKeepAwakeMarker(in tile: NSRect) {
        let size = tile.width * 0.17
        let rect = NSRect(x: tile.midX - size / 2, y: tile.midY - size / 2,
                          width: size, height: size)
        LoadPalette.amber.setFill()
        NSBezierPath(ovalIn: rect).fill()
        let config = NSImage.SymbolConfiguration(pointSize: size * 0.5, weight: .bold)
            .applying(.init(paletteColors: [NSColor(calibratedWhite: 0.1, alpha: 1)]))
        guard let symbol = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: "Keep awake on")?
            .withSymbolConfiguration(config) else { return }
        let symbolSize = symbol.size
        symbol.draw(in: NSRect(x: rect.midX - symbolSize.width / 2, y: rect.midY - symbolSize.height / 2,
                               width: symbolSize.width, height: symbolSize.height))
    }

}

/// Green, amber, red by load, shared by the Dock tile and the dashboard so a
/// metric reads the same colour in both places.
enum LoadPalette {
    static let green = NSColor(calibratedRed: 0.27, green: 0.85, blue: 0.55, alpha: 1)
    static let amber = NSColor(calibratedRed: 1.0, green: 0.74, blue: 0.2, alpha: 1)
    static let red = NSColor(calibratedRed: 1.0, green: 0.33, blue: 0.33, alpha: 1)

    /// `fraction` is 0...1. Battery reads "good" when high, the rest when low.
    static func color(for fraction: Double, highIsGood: Bool) -> NSColor {
        let load = highIsGood ? 1 - fraction : fraction
        switch load {
        case ..<0.6: return green
        case ..<0.85: return amber
        default: return red
        }
    }
}
