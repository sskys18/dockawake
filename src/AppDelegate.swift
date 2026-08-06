import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let statusStrip = StatusStripView()
    private let popover = NSPopover()
    private let dashboard = DashboardViewController()
    private let scheduler = DispatchScheduler(queue: DispatchQueue(label: "com.dockawake.scheduler", qos: .utility))
    private var summaryController: SystemSummaryController?
    private var keepAwakeController: KeepAwakeController?
    private var detailSession: DetailCollectionSession?
    private let containerCollector = ContainerCollector()
    private let containerQueue = DispatchQueue(label: "com.dockawake.containers", qos: .userInitiated)
    private var detailGeneration: UInt64 = 0
    private var escapeMonitor: Any?
    private var latestAwakeText = "Unknown"
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItem()
        configurePopover()
        configureControllers()
        installSignalHandlers()
        summaryController?.start()
        keepAwakeController?.adoptCurrentState()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = nil
        button.attributedTitle = statusStrip.attributedTitle
        button.wantsLayer = true
        button.layer?.cornerRadius = 9
        button.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.92).cgColor
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.length = NSStatusItem.variableLength
        refreshTooltip()
        button.setAccessibilityLabel("DockAwake system status")
    }

    /// The tooltip is the only surface that can name each strip icon, so it
    /// spells out every metric plus the current keep-awake state.
    private func refreshTooltip() {
        let lines = [
            statusStrip.labeledSummary,
            "Keep awake: \(latestAwakeText)",
            "Click to open the dashboard"
        ]
        statusItem.button?.toolTip = lines.joined(separator: "\n")
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = dashboard
    }

    private func configureControllers() {
        dashboard.onAwakeChange = { [weak self] desired in
            self?.keepAwakeController?.setDesired(desired)
        }
        dashboard.onContainerStop = { [weak self] containerID, completion in
            guard let self else { return }
            self.containerQueue.async {
                let succeeded = self.containerCollector.stop(containerID: containerID)
                DispatchQueue.main.async { completion(succeeded) }
            }
        }
        summaryController = SystemSummaryController(scheduler: scheduler) { [weak self] snapshot in
            guard let self else { return }
            self.statusStrip.update(with: snapshot)
            self.statusItem.button?.attributedTitle = self.statusStrip.attributedTitle
            self.statusItem.button?.setAccessibilityValue(Self.summaryAccessibilityText(snapshot))
            self.refreshTooltip()
        }
        keepAwakeController = KeepAwakeController(
            runner: CommandRunner(),
            scheduler: scheduler,
            publish: { [weak self] state in
                guard let self else { return }
                self.dashboard.updateKeepAwake(state)
                self.latestAwakeText = Self.keepAwakeText(state)
                self.refreshTooltip()
            })
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            popover.performClose(nil)
            showMenu()
        } else {
            toggleDashboard()
        }
    }

    private func toggleDashboard() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        startDetailSession()
        installEscapeMonitor()
    }

    @objc private func openDashboard() {
        guard !popover.isShown else { return }
        toggleDashboard()
    }

    private func startDetailSession() {
        detailGeneration &+= 1
        let generation = detailGeneration
        let session = DetailCollectionSession(
            generation: generation,
            scheduler: scheduler,
            networkCollector: NetworkCollector(),
            publicIPClient: PublicIPClient(),
            processCollector: ProcessCollector(),
            powerAssertionCollector: PowerAssertionCollector(),
            containerCollector: containerCollector,
            publish: { [weak self] snapshot in
                guard let self,
                      self.detailSession != nil,
                      self.detailGeneration == snapshot.generation else { return }
                self.dashboard.updateDetail(snapshot)
            })
        detailSession = session
        session.start()
    }

    private func showMenu() {
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Dashboard", action: #selector(openDashboard), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let awake = NSMenuItem(title: "Keep Awake: \(Self.keepAwakeTextFromDashboard())", action: nil, keyEquivalent: "")
        awake.isEnabled = false
        menu.addItem(awake)
        menu.addItem(.separator())
        let login = NSMenuItem(title: "Start at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func toggleLoginItem() {
        if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
        } else {
            try? SMAppService.mainApp.register()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        detailSession?.stop()
        detailSession = nil
        dashboard.clearDetail()
        removeEscapeMonitor()
    }

    private func installEscapeMonitor() {
        removeEscapeMonitor()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, self?.popover.isShown == true {
                self?.popover.performClose(nil)
                return nil
            }
            return event
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
    }


    private func installSignalHandlers() {
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        summaryController?.stop()
        detailSession?.stop()
        detailSession = nil
        removeEscapeMonitor()
        keepAwakeController?.shutdownAndRestoreSleep()
    }

    private static var latestKeepAwakeText = "Unknown"

    private static func keepAwakeText(_ state: KeepAwakeUIState) -> String {
        let rendered: String
        switch state.current {
        case .available(true): rendered = "Enabled"
        case .available(false): rendered = "Disabled"
        case .unavailable: rendered = "Unavailable"
        case .unknown: rendered = "Unknown"
        }
        latestKeepAwakeText = rendered
        return rendered
    }

    private static func keepAwakeTextFromDashboard() -> String {
        latestKeepAwakeText
    }

    private static func summaryAccessibilityText(_ snapshot: SystemSummarySnapshot) -> String {
        let labels = ["CPU", "Memory", "Storage", "Battery"]
        let metrics = [snapshot.cpu, snapshot.memory, snapshot.storage, snapshot.battery]
        return zip(labels, metrics).map { label, metric in
            let value: String
            switch metric {
            case let .available(display): value = display.text
            case .unavailable, .unknown: value = "N/A"
            }
            return "\(label) \(value)"
        }.joined(separator: ", ")
    }
}
