import AppKit

// DockAwake: menu bar toggle for closed-lid keep-awake.
// Left-click the menu bar icon to toggle. Right-click for a menu.
// ON  -> sudo -n /Library/PrivilegedHelperTools/dockawake-pmset on   (pmset -a disablesleep 1)
// OFF -> sudo -n /Library/PrivilegedHelperTools/dockawake-pmset off  (pmset -a disablesleep 0)
// Quitting the app always restores normal sleep.

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let helperPath = "/Library/PrivilegedHelperTools/dockawake-pmset"
    private var awake = false
    private var lastError = false
    private var verifyTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Adopt whatever the system state currently is (e.g. after a crash).
        awake = Self.readSleepDisabled()
        updateStatusIcon()

        verifyTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.verifyState()
        }
        verifyTimer?.tolerance = 2

        // Restore sleep on SIGTERM/SIGINT (logout, kill) too.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { NSApp.terminate(nil) }
            src.resume()
            signalSources.append(src)
        }
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            toggle()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        let title = awake ? "Allow Sleep (OFF)" : "Keep Awake (ON)"
        let toggleItem = NSMenuItem(title: title, action: #selector(toggleAction), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        let stateItem = NSMenuItem(
            title: lastError ? "Status: ERROR (check helper)" : (awake ? "Status: staying awake" : "Status: normal sleep"),
            action: nil, keyEquivalent: "")
        stateItem.isEnabled = false
        menu.addItem(stateItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit DockAwake", action: #selector(quitAction), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil // restore click-to-toggle behavior
    }

    @objc private func toggleAction() { toggle() }
    @objc private func quitAction() { NSApp.terminate(nil) }

    private func toggle() {
        setAwake(!awake)
    }

    private func setAwake(_ desired: Bool) {
        let ran = runHelper(desired ? "on" : "off")
        let actual = Self.readSleepDisabled()
        awake = actual
        lastError = !ran || actual != desired
        updateStatusIcon()
        if lastError {
            // Retry once shortly after a failure, then reverify.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.lastError else { return }
                _ = self.runHelper(desired ? "on" : "off")
                self.verifyState(expected: desired)
            }
        }
    }

    private func verifyState(expected: Bool? = nil) {
        let actual = Self.readSleepDisabled()
        if let expected { lastError = actual != expected }
        if actual != awake || expected != nil {
            awake = actual
            updateStatusIcon()
        }
    }

    @discardableResult
    private func runHelper(_ mode: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", helperPath, mode]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            return false
        }
    }

    static func readSleepDisabled() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let out = String(data: data, encoding: .utf8) else { return false }
        for line in out.split(separator: "\n") where line.contains("SleepDisabled") {
            return line.trimmingCharacters(in: .whitespaces).hasSuffix("1")
        }
        return false
    }

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        let symbolName: String
        if lastError { symbolName = "exclamationmark.triangle.fill" }
        else if awake { symbolName = "cup.and.saucer.fill" }
        else { symbolName = "moon.zzz" }
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "DockAwake")?
            .withSymbolConfiguration(config)
        if lastError {
            button.image = image?.tinted(.systemRed)
            button.image?.isTemplate = false
        } else if awake {
            button.image = image?.tinted(.systemGreen)
            button.image?.isTemplate = false
        } else {
            image?.isTemplate = true
            button.image = image
        }
        button.toolTip = lastError
            ? "DockAwake: ERROR (check helper)"
            : (awake ? "DockAwake: staying awake (click to allow sleep)" : "DockAwake: normal sleep (click to keep awake)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Always restore normal sleep on clean exit.
        if Self.readSleepDisabled() {
            _ = runHelper("off")
        }
    }
}

extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        return image
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
