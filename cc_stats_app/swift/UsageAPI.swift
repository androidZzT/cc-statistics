import Foundation

/// Fetches Claude usage quota from Anthropic OAuth API.
/// Token is user-provided via Settings, stored in UserDefaults.
enum UsageAPI {

    static let tokenKey = "cc_stats_api_token"
    static let tokenExpiredKey = "cc_stats_token_expired"

    struct UsageData {
        let fiveHourPercent: Int       // 0-100
        let fiveHourResetsAt: Date?
        let sevenDayPercent: Int       // 0-100
        let sevenDayResetsAt: Date?
    }

    enum FetchResult {
        case success(UsageData)
        case tokenExpired   // HTTP 401 or 403
        case networkError   // other errors
        case noToken        // token not configured
    }

    /// Fetch current usage quota with detailed result.
    static func fetch(completion: @escaping (FetchResult) -> Void) {
        guard let token = UserDefaults.standard.string(forKey: tokenKey),
              !token.isEmpty else {
            completion(.noToken)
            return
        }

        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            completion(.networkError)
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("cc-statistics/\(SettingsView.appVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                    UserDefaults.standard.set(true, forKey: tokenExpiredKey)
                    completion(.tokenExpired)
                    return
                }
            }

            guard let data = data, error == nil,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(.networkError)
                return
            }

            UserDefaults.standard.set(false, forKey: tokenExpiredKey)

            let fiveHour = json["five_hour"] as? [String: Any]
            let sevenDay = json["seven_day"] as? [String: Any]

            let result = UsageData(
                fiveHourPercent: fiveHour?["utilization"] as? Int ?? 0,
                fiveHourResetsAt: parseISO8601(fiveHour?["resets_at"] as? String),
                sevenDayPercent: sevenDay?["utilization"] as? Int ?? 0,
                sevenDayResetsAt: parseISO8601(sevenDay?["resets_at"] as? String)
            )
            completion(.success(result))
        }.resume()
    }

    private static func parseISO8601(_ string: String?) -> Date? {
        guard let string = string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    static func formatResetTime(_ date: Date?) -> String {
        guard let date = date else { return "" }
        let diff = date.timeIntervalSinceNow
        if diff <= 0 { return "now" }
        let hours = Int(diff / 3600)
        let minutes = Int(diff.truncatingRemainder(dividingBy: 3600) / 60)
        if hours > 0 {
            return "\(hours)h\(minutes)m"
        }
        return "\(minutes)m"
    }
}
