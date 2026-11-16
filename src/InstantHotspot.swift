import Foundation

/// Wakes an iPhone Personal Hotspot over Bluetooth (Instant Hotspot) through the private
/// Sharing.framework `SFRemoteHotspotSession`, the same path the Wi-Fi menu uses.
/// `networksetup` alone cannot join because the phone does not broadcast its SSID until woken.
final class InstantHotspot: NSObject {
    enum Failure: Error, CustomStringConvertible {
        case unavailable
        case deviceNotFound(String)
        case enableFailed

        var description: String {
            switch self {
            case .unavailable: return "Instant Hotspot is unavailable on this Mac"
            case .deviceNotFound(let name): return "\(name) was not found nearby (Bluetooth on, same Apple ID?)"
            case .enableFailed: return "the iPhone did not turn on its hotspot"
            }
        }
    }

    private let deviceName: String
    private var session: NSObject?
    private var completion: ((Result<String, Failure>) -> Void)?

    init(deviceName: String) {
        self.deviceName = deviceName
    }

    /// Calls back on the main queue with the hotspot password once the phone is broadcasting.
    /// The instance keeps itself alive until it calls back.
    func enable(timeout: TimeInterval = 15, completion: @escaping (Result<String, Failure>) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard dlopen("/System/Library/PrivateFrameworks/Sharing.framework/Sharing", RTLD_NOW) != nil,
              let cls = NSClassFromString("SFRemoteHotspotSession") as? NSObject.Type else {
            completion(.failure(.unavailable))
            return
        }
        let session = cls.init()
        self.session = session
        self.completion = completion
        session.perform(NSSelectorFromString("setDelegate:"), with: self)
        session.perform(NSSelectorFromString("startBrowsing"))
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            self.finish(.failure(.deviceNotFound(self.deviceName)))
        }
    }

    /// SFRemoteHotspotSessionDelegate callback, delivered on an XPC queue.
    @objc(session:updatedFoundDevices:)
    func session(_ session: NSObject, updatedFoundDevices devices: [NSObject]) {
        guard let device = devices.first(where: { $0.value(forKey: "deviceName") as? String == deviceName }) else { return }
        DispatchQueue.main.async { self.enable(device) }
    }

    private func enable(_ device: NSObject) {
        guard let session, completion != nil else { return }
        session.perform(NSSelectorFromString("stopBrowsing"))
        let handler: @convention(block) (AnyObject?) -> Void = { info in
            let password = (info as? NSObject)?.value(forKey: "password") as? String
            DispatchQueue.main.async {
                self.finish(password.map { .success($0) } ?? .failure(.enableFailed))
            }
        }
        session.perform(NSSelectorFromString("enableRemoteHotspotForDevice:withCompletionHandler:"),
                        with: device, with: handler as AnyObject)
    }

    private func finish(_ result: Result<String, Failure>) {
        guard let completion else { return }
        self.completion = nil
        session?.perform(NSSelectorFromString("stopBrowsing"))
        session = nil
        completion(result)
    }
}
