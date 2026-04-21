import Foundation

enum BridgeConfiguration {
    static let appGroupID = "group.ccstats.island"
    static let baseURLKey = "bridge_base_url"

    static func bridgeBaseURL() -> URL {
        if let group = UserDefaults(suiteName: appGroupID),
           let text = group.string(forKey: baseURLKey),
           let url = URL(string: text),
           ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            return url
        }
        return URL(string: "http://127.0.0.1:8765")!
    }
}
