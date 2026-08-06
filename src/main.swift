import AppKit
import ServiceManagement

// CLI escape hatches for scripts (used by install.sh and uninstall.sh).
if CommandLine.arguments.contains("--unregister-login-item") {
    try? SMAppService.mainApp.unregister()
    exit(0)
}

if CommandLine.arguments.contains("--register-login-item") {
    do {
        try SMAppService.mainApp.register()
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("register-login-item failed: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

if CommandLine.arguments.contains("--login-item-status") {
    let status = SMAppService.mainApp.status
    switch status {
    case .enabled: print("enabled")
    case .notRegistered: print("notRegistered")
    case .requiresApproval: print("requiresApproval")
    case .notFound: print("notFound")
    @unknown default: print("unknown(\(status.rawValue))")
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()