import CoreWLAN
import Foundation

enum HotspotState: Equatable {
    case off
    case on
    case unavailable(String)
}

/// Joins and leaves the configured iPhone Personal Hotspot. Joining wakes the phone over
/// Instant Hotspot first, since the phone does not broadcast its SSID until woken.
final class HotspotController {
    let ssid: String?

    init(ssid: String?) {
        self.ssid = ssid
    }

    /// CoreWLAN hides the SSID without Location Services, so the hotspot is recognised by the
    /// addresses iOS hands out: 172.20.10.0/28, or 192.0.0.2 on IPv6-only carriers (464XLAT).
    func currentState() -> HotspotState {
        guard ssid != nil else { return .unavailable("not configured") }
        let result = CommandRunner().run(executable: "/sbin/ifconfig", arguments: ["en0", "inet"], outputLimit: 16 * 1024)
        guard result.succeeded else { return .unavailable("Wi-Fi unreadable") }
        return Self.parse(String(decoding: result.output, as: UTF8.self))
    }

    static func parse(_ ifconfig: String) -> HotspotState {
        for line in ifconfig.split(separator: "\n") {
            let fields = line.split(separator: " ")
            guard fields.count >= 2, fields[0].hasSuffix("inet") else { continue }
            let address = fields[1]
            if address.hasPrefix("172.20.10.") || address == "192.0.0.2" { return .on }
        }
        return .off
    }

    /// Main-queue completion with nil on success, otherwise an error message.
    func turnOn(completion: @escaping (String?) -> Void) {
        guard let ssid else { completion("not configured"); return }
        InstantHotspot(deviceName: ssid).enable { result in
            switch result {
            case .failure(let failure):
                completion(failure.description)
            case .success(let password):
                DispatchQueue.global(qos: .userInitiated).async {
                    let message = Self.join(ssid, password: password)
                    DispatchQueue.main.async { completion(message) }
                }
            }
        }
    }

    func turnOff(completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            CWWiFiClient.shared().interface()?.disassociate()
            DispatchQueue.main.async { completion(nil) }
        }
    }

    /// networksetup exits 0 even on failure and reports errors on stdout; the SSID can take a
    /// few seconds to appear after the wake, so retry briefly.
    private static func join(_ ssid: String, password: String) -> String? {
        var message = "networksetup failed"
        for attempt in 0..<5 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 2) }
            let result = CommandRunner().run(
                executable: "/usr/sbin/networksetup",
                arguments: ["-setairportnetwork", "en0", ssid, password],
                outputLimit: 4096,
                timeout: 30)
            let output = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if result.succeeded && output.isEmpty { return nil }
            if !output.isEmpty { message = output }
        }
        return message
    }
}
