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
    private let localConfig = LocalConfig.load()
    private lazy var exitNode = ExitNodeController(nodeIP: localConfig.exitNodeIP)
    private var exitNodeState: ExitNodeState = .unavailable("checking") {
        didSet { dashboard.updateSurfshark(exitNodeState, applying: exitNodeApplying) }
    }
    private var exitNodeApplying = false {
        didSet { dashboard.updateSurfshark(exitNodeState, applying: exitNodeApplying) }
    }
    private var dashboardStatusItem: NSStatusItem?
    private lazy var hotspot = HotspotController(ssid: localConfig.hotspotSSID)
    private var hotspotState: HotspotState = .unavailable("checking") {
        didSet { updateDashboardHotspot() }
    }
    private var hotspotApplying = false {
        didSet { updateDashboardHotspot() }
    }

    private func updateDashboardHotspot() {
        dashboard.updateHotspot(hotspotState, applying: hotspotApplying)
        let busy = hotspotApplying || keepAwakeState?.pendingIntent != nil
        var available = true
        if case .unavailable = hotspotState { available = false }
        dashboard.updateMobile(on: mobileOn, enabled: available && !busy)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.dockTile.contentView = dockTile
        dockTile.onNeedsDockRefresh = { NSApp.dockTile.display() }
        NSApp.dockTile.display()
        NSApp.mainMenu = Self.makeMainMenu()
        configureControllers()
        installSignalHandlers()
        summaryController?.start()
        keepAwakeController?.adoptCurrentState()
        installDashboardStatusItem()
        refreshExitNodeState()
        refreshHotspotState()
    }

    /// Menu bar button: left click opens the dashboard, right click shows the same controls as the Dock menu.
    private func installDashboardStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: "Open DockAwake dashboard")
        item.button?.image?.isTemplate = true
        item.button?.toolTip = "Open DockAwake dashboard (right click: Keep Awake, hotspot, Surfshark)"
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        dashboardStatusItem = item
    }

    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent,
              event.type == .rightMouseUp || event.modifierFlags.contains(.control) else {
            openDashboard()
            return
        }
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Dashboard", action: #selector(openDashboard), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        controlMenuItems().forEach(menu.addItem)
        guard let button = dashboardStatusItem?.button else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    /// The controls shared by the menu bar and Dock menus, so both always offer the same thing.
    /// Menus are built synchronously, so they show the last read state and start a fresh read.
    private func controlMenuItems() -> [NSMenuItem] {
        refreshExitNodeState()
        refreshHotspotState()
        return [mobileMenuItem(), .separator(), keepAwakeMenuItem(), hotspotMenuItem(), exitNodeMenuItem()]
    }

    /// Both Keep Awake and the hotspot on, the setup for working off the phone.
    private var mobileOn: Bool {
        hotspotState == .on && keepAwakeState?.current == .available(true)
    }

    private func mobileMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Hotspot + Keep Awake", action: #selector(toggleMobile), keyEquivalent: "")
        item.target = self
        item.state = mobileOn ? .on : .off
        if hotspotApplying || keepAwakeState?.pendingIntent != nil {
            item.title = "Hotspot + Keep Awake: Applying…"
            item.action = nil
        }
        if case .unavailable = hotspotState { item.action = nil }
        return item
    }

    @objc private func toggleMobile() {
        setMobile(!mobileOn)
    }

    /// One switch for both: on turns the hotspot on (which turns Keep Awake on), off turns both off.
    private func setMobile(_ desired: Bool) {
        if !desired { keepAwakeController?.setDesired(false) }
        if (hotspotState == .on) != desired { setHotspot(desired) } else if desired { keepAwakeController?.setDesired(true) }
    }

    private func keepAwakeMenuItem() -> NSMenuItem {
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
        return awake
    }

    private func hotspotMenuItem() -> NSMenuItem {
        let name = hotspot.ssid.map { "\($0) Hotspot" } ?? "Hotspot"
        let item = NSMenuItem(title: name, action: #selector(toggleHotspot), keyEquivalent: "")
        item.target = self
        if hotspotApplying {
            item.title = "\(name): Applying…"
            item.action = nil
            return item
        }
        switch hotspotState {
        case .on: item.state = .on
        case .off: item.state = .off
        case let .unavailable(reason):
            item.title = "\(name): \(reason)"
            item.action = nil
        }
        return item
    }

    @objc private func toggleHotspot() {
        setHotspot(hotspotState != .on)
    }

    /// Turning the hotspot on also turns Keep Awake on; the hotspot-proxy watcher takes it from there.
    private func setHotspot(_ desired: Bool) {
        guard !hotspotApplying else { return }
        if case .unavailable = hotspotState { return }
        hotspotApplying = true
        if desired { keepAwakeController?.setDesired(true) }
        let done: (String?) -> Void = { [weak self] message in
            guard let self else { return }
            if let message { self.showHotspotFailure(desired, message) }
            // Wi-Fi takes a moment to drop or gain the hotspot address after the call returns.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self.hotspotApplying = false
                self.refreshHotspotState()
            }
        }
        if desired { hotspot.turnOn(completion: done) } else { hotspot.turnOff(completion: done) }
    }

    private func refreshHotspotState() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let state = self.hotspot.currentState()
            DispatchQueue.main.async { self.hotspotState = state }
        }
    }

    private func showHotspotFailure(_ joining: Bool, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = joining ? "Could not join \(hotspot.ssid ?? "the hotspot")" : "Could not leave the hotspot"
        alert.informativeText = message
        alert.runModal()
    }

    /// The Dock menu is built synchronously, so it shows the last read state and starts a fresh read.
    private func refreshExitNodeState() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let state = self.exitNode.currentState()
            DispatchQueue.main.async { self.exitNodeState = state }
        }
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
        dashboard.onSurfsharkChange = { [weak self] desired in
            self?.setExitNode(desired)
        }
        dashboard.onHotspotChange = { [weak self] desired in
            self?.setHotspot(desired)
        }
        dashboard.onMobileChange = { [weak self] desired in
            self?.setMobile(desired)
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
                self.updateDashboardHotspot()
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
        refreshExitNodeState()
        refreshHotspotState()
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
        controlMenuItems().forEach(menu.addItem)
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

    private func exitNodeMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Surfshark", action: nil, keyEquivalent: "")
        if exitNodeApplying {
            item.title = "Surfshark: Applying…"
            return item
        }
        var current: String?
        switch exitNodeState {
        case let .on(server):
            current = server
            item.title = "Surfshark: \(SurfsharkServer.label(for: server))"
        case .off: item.title = "Surfshark: Off"
        case let .other(host): item.title = "Surfshark (exit node now \(host))"
        case let .unavailable(reason): item.title = "Surfshark: \(reason)"
        }
        let submenu = NSMenu()
        let off = NSMenuItem(title: "Off", action: #selector(selectExitNode(_:)), keyEquivalent: "")
        off.target = self
        off.state = exitNodeState == .off ? .on : .off
        submenu.addItem(off)
        for server in SurfsharkServer.all {
            let choice = NSMenuItem(title: server.label, action: #selector(selectExitNode(_:)), keyEquivalent: "")
            choice.target = self
            choice.representedObject = server.id
            choice.state = current == server.id ? .on : .off
            submenu.addItem(choice)
        }
        item.submenu = submenu
        return item
    }

    @objc private func selectExitNode(_ sender: NSMenuItem) {
        setExitNode(sender.representedObject as? String)
    }

    private func setExitNode(_ server: String?) {
        guard !exitNodeApplying else { return }
        exitNodeApplying = true
        exitNode.select(server: server) { [weak self] state in
            self?.exitNodeApplying = false
            self?.exitNodeState = state
        }
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
