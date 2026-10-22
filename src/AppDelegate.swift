import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let dockTile = DockTileView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
    private lazy var window: NSWindow = makeWindow()
    private let dashboard = DashboardViewController()
    private let scheduler = DispatchScheduler(queue: DispatchQueue(label: "com.dockawake.scheduler", qos: .utility))
    private var summaryController: SystemSummaryController?
    private var keepAwakeController: KeepAwakeController?
    private var alertTracker = DockAlertTracker()
    private var latestSnapshot: SystemSummarySnapshot?
    private var keepAwakeState: KeepAwakeUIState?
    private var detailSession: DetailCollectionSession?
    private let containerCollector = ContainerCollector()
    private let launchAgentCollector = LaunchAgentCollector()
    private let containerQueue = DispatchQueue(label: "com.dockawake.containers", qos: .userInitiated)
    private var detailGeneration: UInt64 = 0
    private var escapeMonitor: Any?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.dockTile.contentView = dockTile
        dockTile.onNeedsDockRefresh = { NSApp.dockTile.display() }
        NSApp.dockTile.display()
        NSApp.mainMenu = Self.makeMainMenu()
        configureControllers()
        installSignalHandlers()
        summaryController?.start()
        keepAwakeController?.adoptCurrentState()
    }

    private static func makeMainMenu() -> NSMenu {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit DockAwake", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        let main = NSMenu()
        for (title, submenu) in [("DockAwake", appMenu), ("Window", windowMenu)] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            main.addItem(item)
        }
        return main
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: dashboard)
        window.title = "DockAwake"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 1100, height: 620)
        window.setFrameAutosaveName("DockAwakeDashboard")
        window.delegate = self
        window.center()
        return window
    }

    private func configureControllers() {
        dashboard.onAwakeChange = { [weak self] desired in
            self?.keepAwakeController?.setDesired(desired)
        }
        dashboard.onContainerStop = { [weak self] containerIDs, completion in
            guard let self else { return }
            // Stops run one after another on a single queue: the runtime serializes
            // them anyway, and a sequential pass reports one honest result per ID.
            self.containerQueue.async {
                var results: [String: Bool] = [:]
                for containerID in containerIDs {
                    results[containerID] = self.containerCollector.stop(containerID: containerID)
                }
                DispatchQueue.main.async { completion(results) }
            }
        }
        summaryController = SystemSummaryController(scheduler: scheduler) { [weak self] snapshot in
            guard let self else { return }
            self.latestSnapshot = snapshot
            self.dockTile.update(with: snapshot)
            self.dashboard.updateSummary(snapshot)
            if self.alertTracker.update(with: snapshot) {
                NSApp.requestUserAttention(.informationalRequest)
            }
            NSApp.dockTile.badgeLabel = self.alertTracker.badge
            self.dockTile.setAccessibilityValue(Self.summaryAccessibilityText(snapshot))
        }
        keepAwakeController = KeepAwakeController(
            runner: CommandRunner(),
            scheduler: scheduler,
            publish: { [weak self] state in
                guard let self else { return }
                self.dashboard.updateKeepAwake(state)
                self.keepAwakeState = state
                self.dockTile.keepAwake = state.current.value == true
            })
    }

    /// Clicking the Dock icon opens the dashboard window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openDashboard()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @objc private func openDashboard() {
        if !window.isVisible || window.isMiniaturized {
            if detailSession == nil { startDetailSession() }
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installEscapeMonitor()
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
            launchAgentCollector: launchAgentCollector,
            hotspotProxyCollector: HotspotProxyCollector(),
            publish: { [weak self] snapshot in
                guard let self,
                      self.detailSession != nil,
                      self.detailGeneration == snapshot.generation else { return }
                self.dashboard.updateDetail(snapshot)
            })
        detailSession = session
        session.start()
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Dashboard", action: #selector(openDashboard), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        if let snapshot = latestSnapshot {
            for line in Self.summaryAccessibilityText(snapshot).components(separatedBy: ", ") {
                let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        let awake = NSMenuItem(title: "Keep Awake", action: #selector(toggleKeepAwake), keyEquivalent: "")
        awake.target = self
        switch keepAwakeState?.current {
        case .available(true): awake.state = .on
        case .available(false): awake.state = .off
        case .unavailable, .unknown, .none:
            awake.title = "Keep Awake: Unavailable"
            awake.action = nil
        }
        if keepAwakeState?.pendingIntent != nil {
            awake.title = "Keep Awake: Applying…"
            awake.action = nil
        }
        menu.addItem(awake)
        menu.addItem(.separator())
        let login = NSMenuItem(title: "Start at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        return menu
    }

    @objc private func toggleKeepAwake() {
        guard case let .available(enabled) = keepAwakeState?.current else { return }
        keepAwakeController?.setDesired(!enabled)
    }

    @objc private func toggleLoginItem() {
        if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
        } else {
            try? SMAppService.mainApp.register()
        }
    }

    func windowWillClose(_ notification: Notification) {
        detailSession?.stop()
        detailSession = nil
        dashboard.clearDetail()
        removeEscapeMonitor()
    }

    private func installEscapeMonitor() {
        removeEscapeMonitor()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, let window = self?.window, window.isKeyWindow {
                window.performClose(nil)
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

    private static func summaryAccessibilityText(_ snapshot: SystemSummarySnapshot) -> String {
        let labels = ["CPU", "Memory", "Storage", "Battery"]
        let metrics = [snapshot.cpu, snapshot.memory, snapshot.storage, snapshot.battery]
        var parts = zip(labels, metrics).map { label, metric -> String in
            let value: String
            switch metric {
            case let .available(display): value = display.text
            case .unavailable, .unknown: value = "N/A"
            }
            return "\(label) \(value)"
        }
        if let power = snapshot.batteryPower.value {
            parts.append(power.text)
        }
        return parts.joined(separator: ", ")
    }
}
