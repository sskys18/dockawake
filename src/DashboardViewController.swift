import AppKit

private struct TextColumn {
    let title: String
    let width: CGFloat
    let alignment: NSTextAlignment
    let help: String
}

/// A compact read-only table used for the network and power-assertion cards so
/// their fields stay in aligned columns instead of one long sentence.
private final class TextTableView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private let columns: [TextColumn]
    private var rows: [[String]] = []
    private let emptyLabel = NSTextField(labelWithString: "N/A")
    /// Returns the colour for one cell by row and column, or nil for the default.
    /// Colour here is state, never decoration.
    var cellColor: ((Int, Int) -> NSColor?)?
    var onSelectionChange: (() -> Void)?
    var selectedRowIndexes: IndexSet { table.selectedRowIndexes }

    init(columns: [TextColumn], accessibilityLabel: String, visibleRows: Int, allowsSelection: Bool = false) {
        self.columns = columns
        super.init(frame: .zero)

        for (index, column) in columns.enumerated() {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("text.\(index)"))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = 40
            tableColumn.headerToolTip = column.help
            table.addTableColumn(tableColumn)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 24
        table.style = .fullWidth
        table.intercellSpacing = NSSize(width: 6, height: 2)
        table.usesAlternatingRowBackgroundColors = true
        table.allowsColumnReordering = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.setAccessibilityLabel(accessibilityLabel)
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = allowsSelection
        table.selectionHighlightStyle = allowsSelection ? .regular : .none

        table.backgroundColor = .controlBackgroundColor
        let scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .controlBackgroundColor
        scrollView.borderType = .noBorder
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 8
        scrollView.layer?.borderWidth = 1
        scrollView.layer?.borderColor = NSColor.separatorColor.cgColor
        scrollView.layer?.masksToBounds = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyLabel)
        // The table should absorb whatever height its tab page has spare.
        setContentHuggingPriority(.defaultLow, for: .vertical)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: CGFloat(visibleRows) * 24 + 28),
            emptyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            emptyLabel.topAnchor.constraint(equalTo: topAnchor, constant: 30)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func update(_ rows: [[String]]) {
        let previous = IndexSet(table.selectedRowIndexes.filter { $0 < rows.count })
        self.rows = rows
        emptyLabel.isHidden = !rows.isEmpty
        table.reloadData()
        // A five-second refresh must not drop the rows the user is about to act on.
        if !previous.isEmpty {
            table.selectRowIndexes(previous, byExtendingSelection: false)
        }
    }

    func setEmptyText(_ text: String) {
        emptyLabel.stringValue = text
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        onSelectionChange?()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let index = table.tableColumns.firstIndex(of: tableColumn) else { return nil }
        let value = index < rows[row].count ? rows[row][index] : "N/A"
        let cell = DashboardCell.make(in: tableView, column: tableColumn, owner: self)
        cell.textField?.stringValue = value
        cell.textField?.alignment = columns[index].alignment
        cell.textField?.setAccessibilityLabel("\(tableColumn.title): \(value)")
        cell.textField?.textColor = cellColor?(row, index) ?? .labelColor
        cell.toolTip = value
        return cell
    }
}

private enum DashboardCell {
    /// Reuses one label-backed cell shape for every dashboard table.
    static func make(in tableView: NSTableView, column: NSTableColumn, owner: Any) -> NSTableCellView {
        let identifier = column.identifier
        let cell = tableView.makeView(withIdentifier: identifier, owner: owner) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = identifier
        if cell.textField == nil {
            let label = NSTextField(labelWithString: "")
            label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            label.lineBreakMode = .byTruncatingMiddle
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            cell.textField = label
        }
        return cell
    }
}

final class DashboardViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onAwakeChange: ((Bool) -> Void)?
    /// Asks the owner to stop the given containers and report, per container ID,
    /// whether it succeeded. The controller never runs commands itself.
    var onContainerStop: (([String], @escaping ([String: Bool]) -> Void) -> Void)?

    private let awakeSwitch = NSSwitch()
    private let awakeStateLabel = NSTextField(labelWithString: "Unknown")
    private let publicIPLabel = NSTextField(labelWithString: "Unavailable")
    private let updatedLabel = NSTextField(labelWithString: "")
    private let networkSummaryLabel = NSTextField(labelWithString: "N/A")
    private var assertionsByPID: [Int32: PowerAssertionRow] = [:]
    private let processTable = NSTableView()
    private var processRows: [ProcessRow] = []
    private var processSort = NSSortDescriptor(key: "2", ascending: false)

    private let containerTable = TextTableView(
        columns: [
            TextColumn(title: "Container", width: 230, alignment: .left, help: "Container name, or its short ID when the runtime reported no name."),
            TextColumn(title: "State", width: 78, alignment: .left, help: "Runtime state. Only running containers hold memory and CPU."),
            TextColumn(title: "Image", width: 210, alignment: .left, help: "Image the container was created from."),
            TextColumn(title: "Status", width: 175, alignment: .left, help: "How long the container has been in its current state."),
            TextColumn(title: "Ports", width: 290, alignment: .left, help: "Published port mappings from this Mac into the container.")
        ],
        accessibilityLabel: "Containers",
        visibleRows: 5,
        allowsSelection: true)
    private let containerSummaryLabel = NSTextField(labelWithString: "")
    private var containersTabItem: NSTabViewItem?
    private var processesTabItem: NSTabViewItem?
    private var launchAgentsTabItem: NSTabViewItem?
    private let containerStopButton = NSButton(title: "Stop Selected", target: nil, action: nil)
    private var containerRows: [ContainerRow] = []

    private let launchAgentTable = TextTableView(
        columns: [
            TextColumn(title: "Label", width: 300, alignment: .left, help: "The launchd job label from the property list."),
            TextColumn(title: "State", width: 92, alignment: .left, help: "Running means launchd currently has a process for the job. Loaded means launchd knows the job but it is not running now."),
            TextColumn(title: "PID", width: 66, alignment: .right, help: "Process ID of the running job, if any."),
            TextColumn(title: "Last exit", width: 74, alignment: .right, help: "Exit status of the job's last run as launchctl reports it. Non-zero means the last run failed."),
            TextColumn(title: "Trigger", width: 150, alignment: .left, help: "When launchd starts this job: at load, kept alive, on an interval, on a calendar, or only manually. Unknown for jobs with no property list here."),
            TextColumn(title: "Program", width: 300, alignment: .left, help: "Program or program arguments the job runs, when a local property list declares it."),
            TextColumn(title: "Source", width: 230, alignment: .left, help: "Property list file inside ~/Library/LaunchAgents, or Elsewhere for a job launchd loaded from outside that directory.")
        ],
        accessibilityLabel: "User launch agents",
        visibleRows: 5)
    private let launchAgentSummaryLabel = NSTextField(labelWithString: "")
    private var launchAgentRows: [LaunchAgentRow] = []

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view = root
        preferredContentSize = NSSize(width: 1240, height: 720)

        awakeSwitch.target = self
        awakeSwitch.action = #selector(awakeSwitchChanged)
        awakeSwitch.setAccessibilityLabel("Keep awake")
        awakeStateLabel.setAccessibilityLabel("Keep-awake state")
        awakeStateLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        let awakeTitle = NSTextField(labelWithString: "Keep Awake")
        awakeTitle.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let awakeRow = NSStackView(views: [awakeTitle, awakeSwitch, awakeStateLabel])
        awakeRow.orientation = .horizontal
        awakeRow.alignment = .centerY
        awakeRow.spacing = 10
        // The only control that changes a system setting stays outside the tabs so
        // it is reachable no matter which tab is selected.
        publicIPLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        publicIPLabel.setAccessibilityLabel("Public IP")
        networkSummaryLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        networkSummaryLabel.setAccessibilityLabel("Network throughput")
        let networkRow = NSStackView(views: [
            secondary("Network"),
            networkSummaryLabel,
            secondary("Public IP"),
            publicIPLabel
        ])
        networkRow.orientation = .horizontal
        networkRow.alignment = .firstBaseline
        networkRow.spacing = 8
        let header = NSStackView(views: [
            awakeRow,
            caption("Stops this Mac from sleeping, including with the lid closed. This is the only switch that changes the system setting; quitting DockAwake always restores normal sleep."),
            networkRow
        ])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 4
        header.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        header.wantsLayer = true
        header.layer?.cornerRadius = 10
        header.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        header.layer?.borderWidth = 1
        header.layer?.borderColor = NSColor.separatorColor.cgColor
        header.translatesAutoresizingMaskIntoConstraints = false

        let tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.addTabViewItem(makeProcessesTab())
        tabView.addTabViewItem(makeContainersTab())
        tabView.addTabViewItem(makeLaunchAgentsTab())
        tabView.setAccessibilityLabel("Dashboard sections")
        tabView.selectFirstTabViewItem(nil)

        root.addSubview(header)
        root.addSubview(tabView)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            tabView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            tabView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            tabView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            tabView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12)
        ])
    }

    private func makeContainersTab() -> NSTabViewItem {
        configureContainerCard()
        let controls = NSStackView(views: [containerStopButton, containerSummaryLabel])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 10
        let item = NSTabViewItem(identifier: "containers")
        item.label = "Containers"
        item.view = page(
            "Containers on the local Docker-compatible runtime. Select one or more rows (Shift or Command click) and press Stop Selected to shut them down through the runtime's own graceful stop; nothing here is killed outright.",
            fill: containerTable,
            footer: controls)
        containersTabItem = item
        return item
    }

    private func makeProcessesTab() -> NSTabViewItem {
        configureProcessTable()
        processTable.backgroundColor = .controlBackgroundColor
        let tableScroll = NSScrollView()
        tableScroll.documentView = processTable
        tableScroll.hasVerticalScroller = true
        tableScroll.hasHorizontalScroller = true
        tableScroll.autohidesScrollers = true
        tableScroll.drawsBackground = true
        tableScroll.backgroundColor = .controlBackgroundColor
        tableScroll.borderType = .noBorder
        tableScroll.wantsLayer = true
        tableScroll.layer?.cornerRadius = 8
        tableScroll.layer?.borderWidth = 1
        tableScroll.layer?.borderColor = NSColor.separatorColor.cgColor
        tableScroll.layer?.masksToBounds = true
        tableScroll.setAccessibilityLabel("Process usage")
        updatedLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        updatedLabel.textColor = .secondaryLabelColor
        let item = NSTabViewItem(identifier: "processes")
        item.label = "Processes"
        item.view = page(
            "What is using this Mac right now. Click any column heading to sort; unavailable values always sort last. CPU is per core, so 100% means one full core of \(ProcessInfo.processInfo.activeProcessorCount) available.",
            fill: tableScroll,
            footer: updatedLabel)
        processesTabItem = item
        return item
    }

    private func makeLaunchAgentsTab() -> NSTabViewItem {
        configureLaunchAgentCard()
        let item = NSTabViewItem(identifier: "launchAgents")
        item.label = "LaunchAgents"
        item.view = page(
            "Every non-Apple launchd job in your user domain: the property lists in ~/Library/LaunchAgents plus every other non-Apple job loaded in your user domain, which writes no file there. Invalid marks a file launchd would reject because it carries no Label. Read-only: DockAwake never loads, unloads, or edits a job.",
            fill: launchAgentTable,
            footer: launchAgentSummaryLabel)
        launchAgentsTabItem = item
        return item
    }



    /// One tab page: a wrapping caption, a table that takes all remaining height,
    /// and an optional footer row pinned to the bottom.
    private func page(_ text: String, fill: NSView, footer: NSView?) -> NSView {
        let container = NSView()
        let captionLabel = caption(text)
        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        fill.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(captionLabel)
        container.addSubview(fill)
        var constraints: [NSLayoutConstraint] = [
            captionLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            captionLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            captionLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            fill.topAnchor.constraint(equalTo: captionLabel.bottomAnchor, constant: 10),
            fill.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            fill.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12)
        ]
        if let footer {
            footer.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(footer)
            constraints += [
                footer.topAnchor.constraint(equalTo: fill.bottomAnchor, constant: 8),
                footer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
                footer.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12),
                footer.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
            ]
        } else {
            constraints.append(fill.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12))
        }
        NSLayoutConstraint.activate(constraints)
        return container
    }

    private func caption(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        return label
    }

    func updateKeepAwake(_ state: KeepAwakeUIState) {
        precondition(Thread.isMainThread)
        let stateText: String
        switch state.current {
        case .available(true):
            stateText = "Enabled"
            awakeSwitch.state = .on
        case .available(false):
            stateText = "Disabled"
            awakeSwitch.state = .off
        case .unavailable:
            stateText = "Unavailable"
            awakeSwitch.state = .off
        case .unknown:
            stateText = "Unknown"
            awakeSwitch.state = .off
        }
        awakeSwitch.isEnabled = state.pendingIntent == nil
        var details = [stateText]
        if state.current.value == nil, let lastKnown = state.lastKnown {
            details.append("last known \(lastKnown ? "Enabled" : "Disabled")")
        }
        if let pendingIntent = state.pendingIntent {
            details.append("applying \(pendingIntent ? "Enabled" : "Disabled")")
        }
        if let helperError = state.helperError {
            details.append(helperError)
        }
        awakeStateLabel.stringValue = details.joined(separator: " · ")
        switch state.current {
        case .available(true): awakeStateLabel.textColor = .systemGreen
        case .available(false): awakeStateLabel.textColor = .secondaryLabelColor
        case .unavailable, .unknown: awakeStateLabel.textColor = .systemOrange
        }
        awakeStateLabel.setAccessibilityValue(awakeStateLabel.stringValue)
    }

    func updateDetail(_ snapshot: DetailSnapshot) {
        precondition(Thread.isMainThread)
        updateNetworkSummary(snapshot.interfaces)
        assertionsByPID = Dictionary(
            snapshot.powerAssertions.compactMap { assertion in
                assertion.ownerPID.map { ($0, assertion) }
            },
            uniquingKeysWith: { first, _ in first })
        switch snapshot.publicIP {
        case let .available(address): publicIPLabel.stringValue = address
        case .unavailable: publicIPLabel.stringValue = "Unavailable"
        case .unknown: publicIPLabel.stringValue = "Checking…"
        }
        publicIPLabel.setAccessibilityValue(publicIPLabel.stringValue)
        updateContainers(snapshot.containers)
        updateLaunchAgents(snapshot.launchAgents)
        processRows = snapshot.processes
        sortProcesses()
        processTable.reloadData()
        updatedLabel.stringValue = "\(processRows.count) processes · updated \(Self.timeFormatter.string(from: snapshot.timestamp))"
        setTabCounts(
            containers: snapshot.containers.runningCount,
            processes: processRows.count,
            launchAgents: snapshot.launchAgents.runningCount)
    }

    func clearDetail() {
        precondition(Thread.isMainThread)
        assertionsByPID.removeAll()
        networkSummaryLabel.stringValue = "N/A"
        publicIPLabel.stringValue = "Unavailable"
        updatedLabel.stringValue = ""
        containerRows.removeAll()
        containerTable.update([])
        containerSummaryLabel.stringValue = ""
        containerStopButton.isEnabled = false
        launchAgentRows.removeAll()
        launchAgentTable.update([])
        launchAgentSummaryLabel.stringValue = ""
        processRows.removeAll()
        processTable.reloadData()
        setTabCounts(containers: nil, processes: nil, launchAgents: nil)
    }

    /// Sums only interfaces that actually carry an address. The two dozen empty
    /// virtual interfaces macOS creates would otherwise bury the real number.
    private func updateNetworkSummary(_ interfaces: [NetworkInterfaceSnapshot]) {
        let active = interfaces.filter { !$0.addresses.isEmpty && $0.name != "lo0" }
        let down = active.compactMap(\.receivedRateBytesPerSecond.value).reduce(0, +)
        let up = active.compactMap(\.sentRateBytesPerSecond.value).reduce(0, +)
        guard !active.isEmpty else {
            networkSummaryLabel.stringValue = "N/A"
            return
        }
        networkSummaryLabel.stringValue = "↓ \(DashboardFormat.rate(down))   ↑ \(DashboardFormat.rate(up))"
        networkSummaryLabel.setAccessibilityValue(networkSummaryLabel.stringValue)
    }

    /// The container count is deliberately the running count, not the total:
    /// stopped containers cost nothing and are not what the tab is warning about.
    private func setTabCounts(containers: Int?, processes: Int?, launchAgents: Int?) {
        containersTabItem?.label = Self.tabLabel("Containers", count: containers)
        processesTabItem?.label = Self.tabLabel("Processes", count: processes)
        launchAgentsTabItem?.label = Self.tabLabel("LaunchAgents", count: launchAgents)
    }

    private static func tabLabel(_ title: String, count: Int?) -> String {
        guard let count else { return title }
        return "\(title) (\(count))"
    }

    @objc private func awakeSwitchChanged() {
        onAwakeChange?(awakeSwitch.state == .on)
    }

    private func updateContainers(_ status: ContainerRuntimeStatus) {
        switch status {
        case .missingCLI:
            containerTable.setEmptyText("No docker CLI found")
        case .daemonUnreachable:
            containerTable.setEmptyText("Runtime not running")
        case .available:
            containerTable.setEmptyText("No containers")
        }
        containerRows = status.rows
        containerTable.update(containerRows.map { row in
            [row.displayName, row.stateText, row.image, row.status, row.portsText]
        })
        containerSummaryLabel.stringValue = status.summaryText
        containerSummaryLabel.textColor = status.runningCount > 0 ? .systemGreen : .secondaryLabelColor
        syncContainerStopButton()
    }

    private func updateLaunchAgents(_ status: LaunchAgentStatus) {
        switch status {
        case .directoryUnreadable:
            launchAgentTable.setEmptyText("No ~/Library/LaunchAgents directory")
        case .runtimeUnreadable:
            launchAgentTable.setEmptyText("launchctl did not answer")
        case .available:
            launchAgentTable.setEmptyText("No user launch agents")
        }
        launchAgentRows = status.rows
        launchAgentTable.update(launchAgentRows.map { row in
            [row.labelText, row.stateText, row.pidText, row.lastExitText, row.triggerText, row.programText, row.sourceText]
        })
        launchAgentSummaryLabel.stringValue = status.summaryText
        launchAgentSummaryLabel.textColor = status.runningCount > 0 ? .systemGreen : .secondaryLabelColor
    }

    private func configureLaunchAgentCard() {
        launchAgentTable.setEmptyText("No user launch agents")
        launchAgentTable.cellColor = { [weak self] row, column in
            guard let self, self.launchAgentRows.indices.contains(row) else { return nil }
            let agent = self.launchAgentRows[row]
            if agent.isInvalid { return column == 1 ? .systemOrange : .secondaryLabelColor }
            if !agent.hasLocalFile, column == 6 { return .secondaryLabelColor }
            if column == 3, agent.failedLastRun { return .systemRed }
            guard agent.isLoaded else { return .secondaryLabelColor }
            return column == 1 && agent.isRunning ? .systemGreen : .labelColor
        }
        launchAgentSummaryLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        launchAgentSummaryLabel.textColor = .secondaryLabelColor
    }

    private func configureContainerCard() {
        containerTable.setEmptyText("No containers")
        containerTable.cellColor = { [weak self] row, column in
            guard let self, self.containerRows.indices.contains(row) else { return nil }
            let container = self.containerRows[row]
            guard container.isRunning else { return .secondaryLabelColor }
            return column == 1 ? .systemGreen : .labelColor
        }
        containerTable.onSelectionChange = { [weak self] in self?.syncContainerStopButton() }
        containerStopButton.target = self
        containerStopButton.action = #selector(stopSelectedContainer)
        containerStopButton.bezelStyle = .rounded
        containerStopButton.controlSize = .regular
        containerStopButton.hasDestructiveAction = true
        containerStopButton.contentTintColor = .systemRed
        containerStopButton.isEnabled = false
        containerStopButton.setAccessibilityLabel("Stop selected container")
        containerSummaryLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        containerSummaryLabel.textColor = .secondaryLabelColor
    }

    /// Only selected, still-running containers can be stopped, so the button
    /// state is derived from the current selection rather than tracked separately.
    private func syncContainerStopButton() {
        let selected = selectedRunningContainers()
        containerStopButton.isEnabled = !selected.isEmpty
        containerStopButton.title = selected.count > 1 ? "Stop Selected (\(selected.count))" : "Stop Selected"
    }

    private func selectedRunningContainers() -> [ContainerRow] {
        containerTable.selectedRowIndexes
            .filter { containerRows.indices.contains($0) }
            .map { containerRows[$0] }
            .filter(\.isRunning)
    }

    @objc private func stopSelectedContainer() {
        let rows = selectedRunningContainers()
        guard !rows.isEmpty, let onContainerStop else { return }
        containerStopButton.isEnabled = false
        containerSummaryLabel.stringValue = rows.count == 1
            ? "Stopping \(rows[0].displayName)…"
            : "Stopping \(rows.count) containers…"
        onContainerStop(rows.map(\.id)) { [weak self] results in
            precondition(Thread.isMainThread)
            guard let self else { return }
            let failed = rows.filter { results[$0.id] != true }
            if failed.isEmpty {
                self.containerSummaryLabel.stringValue = rows.count == 1
                    ? "Stopped \(rows[0].displayName)"
                    : "Stopped \(rows.count) containers"
            } else {
                self.containerSummaryLabel.stringValue =
                    "Stopped \(rows.count - failed.count) of \(rows.count) · failed: \(failed.map(\.displayName).joined(separator: ", "))"
            }
            self.syncContainerStopButton()
        }
    }

    private func configureProcessTable() {
        let columns: [TextColumn] = [
            TextColumn(title: "Process", width: 250, alignment: .left, help: "Executable name. An (exited) suffix marks a process that just disappeared."),
            TextColumn(title: "PID", width: 66, alignment: .right, help: "Process ID assigned by macOS."),
            TextColumn(title: "CPU", width: 78, alignment: .right, help: "Share of one CPU core. 100% is one full core, so multi-threaded work exceeds 100%."),
            TextColumn(title: "Memory", width: 100, alignment: .right, help: "Physical memory footprint of the process."),
            TextColumn(title: "Energy", width: 90, alignment: .right, help: "CPU use spread across all cores. A rough energy hint only, not Activity Monitor Energy Impact."),
            TextColumn(title: "Ports", width: 240, alignment: .left, help: "TCP ports this process is listening on. None means it accepts no connections."),
            TextColumn(title: "Awake", width: 210, alignment: .left, help: "The power assertion this process holds to stop the Mac sleeping, if any. Hover for the reason it gave macOS.")
        ]
        for (index, column) in columns.enumerated() {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("process.\(index)"))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = 44
            tableColumn.headerToolTip = column.help
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: "\(index)", ascending: index != 2)
            processTable.addTableColumn(tableColumn)
        }
        processColumnAlignments = columns.map(\.alignment)
        processTable.delegate = self
        processTable.dataSource = self
        processTable.rowHeight = 24
        processTable.style = .fullWidth
        processTable.intercellSpacing = NSSize(width: 6, height: 2)
        processTable.usesAlternatingRowBackgroundColors = true
        processTable.allowsColumnReordering = false
        processTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        processTable.setAccessibilityLabel("Process CPU, memory, energy proxy, and listening ports")
    }

    private var processColumnAlignments: [NSTextAlignment] = []

    /// Heat colours mark the rows worth acting on. Thresholds are absolute so a
    /// quiet machine shows no colour at all rather than always lighting up its
    /// own top row.
    private func processCellColor(_ row: ProcessRow, column: Int) -> NSColor {
        guard !row.isRetainedMissing else { return .secondaryLabelColor }
        switch column {
        case 2:
            guard let cpu = row.cpuPercent.value else { return .labelColor }
            if cpu >= 100 { return .systemRed }
            if cpu >= 50 { return .systemOrange }
            return .labelColor
        case 3:
            guard let bytes = row.memoryBytes.value else { return .labelColor }
            if bytes >= 4 * 1024 * 1024 * 1024 { return .systemRed }
            if bytes >= 1024 * 1024 * 1024 { return .systemOrange }
            return .labelColor
        case 5:
            return row.ports.value?.isEmpty == false ? .systemBlue : .labelColor
        case 6:
            return assertionsByPID[row.id.pid] == nil ? .labelColor : .systemOrange
        default:
            return .labelColor
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { processRows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let index = processTable.tableColumns.firstIndex(of: tableColumn) else { return nil }
        let cell = DashboardCell.make(in: tableView, column: tableColumn, owner: self)
        let value = processText(processRows[row], column: index)
        cell.textField?.stringValue = value
        cell.toolTip = index == 6 ? (assertionsByPID[processRows[row].id.pid]?.reason ?? value) : value
        cell.textField?.alignment = processColumnAlignments.indices.contains(index) ? processColumnAlignments[index] : .left
        cell.textField?.textColor = processCellColor(processRows[row], column: index)
        cell.textField?.setAccessibilityLabel("\(tableColumn.title): \(value)")
        cell.toolTip = value
        return cell
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        processSort = tableView.sortDescriptors.first ?? processSort
        sortProcesses()
        tableView.reloadData()
    }

    private func sortProcesses() {
        let index = Int(processSort.key ?? "2") ?? 2
        processRows.sort { left, right in
            let leftUnavailable = isUnavailable(left, column: index)
            let rightUnavailable = isUnavailable(right, column: index)
            if leftUnavailable != rightUnavailable { return !leftUnavailable }
            let order = compare(left, right, column: index)
            if order == .orderedSame {
                let byMemory = compare(left.memoryBytes, right.memoryBytes)
                if byMemory != .orderedSame { return byMemory == .orderedDescending }
                return left.id < right.id
            }
            return processSort.ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    private func processText(_ row: ProcessRow, column: Int) -> String {
        switch column {
        case 0: return row.isRetainedMissing ? "\(row.name) (exited)" : row.name
        case 1: return String(row.id.pid)
        case 2: return row.cpuText
        case 3: return row.memoryText
        case 4: return row.energyProxyText
        case 6: return assertionsByPID[row.id.pid]?.type ?? ""
        default:
            switch row.ports {
            case let .available(ports): return ports.isEmpty ? "None" : ports.map(\.displayText).joined(separator: ", ")
            case .unavailable: return "N/A"
            case .unknown: return "Unknown"
            }
        }
    }

    private func isUnavailable(_ row: ProcessRow, column: Int) -> Bool {
        switch column {
        case 2:
            if case .available = row.cpuPercent { return false }
            return true
        case 3:
            if case .available = row.memoryBytes { return false }
            return true
        case 4:
            if case .available = row.energyProxyPercent { return false }
            return true
        case 5:
            if case .available = row.ports { return false }
            return true
        default:
            break
        }
        return false
    }

    private func compare(_ left: ProcessRow, _ right: ProcessRow, column: Int) -> ComparisonResult {
        switch column {
        case 0: return left.name.localizedStandardCompare(right.name)
        case 1: return left.id.pid == right.id.pid ? .orderedSame : (left.id.pid < right.id.pid ? .orderedAscending : .orderedDescending)
        case 2: return compare(left.cpuPercent, right.cpuPercent)
        case 3: return compare(left.memoryBytes, right.memoryBytes)
        case 4: return compare(left.energyProxyPercent, right.energyProxyPercent)
        case 6: return processText(left, column: 6).localizedStandardCompare(processText(right, column: 6))
        default: return processText(left, column: 5).localizedStandardCompare(processText(right, column: 5))
        }
    }

    private func compare<Value: Comparable>(_ left: Availability<Value>, _ right: Availability<Value>) -> ComparisonResult {
        switch (left, right) {
        case let (.available(lhs), .available(rhs)):
            return lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
        case (.available, _): return .orderedAscending
        case (_, .available): return .orderedDescending
        case (.unknown, .unavailable): return .orderedAscending
        case (.unavailable, .unknown): return .orderedDescending
        default: return .orderedSame
        }
    }

    private func secondary(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.textColor = .secondaryLabelColor
        return label
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
