import Foundation

/// Personal network details kept out of the repo, read from `~/.config/dockawake/config.json`:
/// `{"exitNodeIP": "100.x.y.z", "hotspotSSID": "MyPhone"}`. A missing key disables that feature.
struct LocalConfig: Decodable {
    static let path = NSHomeDirectory() + "/.config/dockawake/config.json"

    let exitNodeIP: String?
    let hotspotSSID: String?

    static func load(path: String = LocalConfig.path) -> LocalConfig {
        guard let data = FileManager.default.contents(atPath: path),
              let config = try? JSONDecoder().decode(LocalConfig.self, from: data) else {
            return LocalConfig(exitNodeIP: nil, hotspotSSID: nil)
        }
        return config
    }
}
