import Foundation
import UserNotifications
import AppKit

// MARK: - NotificationManager

/// Manages native macOS notifications via UNUserNotificationCenter.
/// On notification click, activates the user's terminal app (iTerm2 > Terminal.app).
@MainActor
final class NotificationManager: NSObject, ObservableObject {

    static let shared = NotificationManager()

    @Published private(set) var isAuthorized = false

    private let center = UNUserNotificationCenter.current()

    /// Terminal bundle IDs in priority order
    private let terminalBundleIDs = [
        "com.googlecode.iterm2",
        "com.apple.Terminal",
    ]

    private override init() {
        super.init()
        center.delegate = self
        checkAuthorization()
    }

    // MARK: - Authorization

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in
                self?.isAuthorized = granted
            }
        }
    }

    private func checkAuthorization() {
        center.getNotificationSettings { [weak self] settings in
            Task { @MainActor in
                self?.isAuthorized = settings.authorizationStatus == .authorized
            }
        }
    }

    // MARK: - Send Notification

    /// Send a native notification. Requests authorization if needed, falls back to osascript on failure.
    func send(title: String, body: String) {
        let sendNative = { [weak self] in
            guard let self else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.categoryIdentifier = "CC_STATS"

            let request = UNNotificationRequest(
                identifier: "cc-stats-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )

            self.center.add(request) { [weak self] error in
                if error != nil {
                    self?.sendOsascriptFallback(title: title, body: body)
                }
            }
        }

        if isAuthorized {
            sendNative()
        } else {
            // Request authorization first, then send or fallback
            center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
                Task { @MainActor in
                    self?.isAuthorized = granted
                    if granted {
                        sendNative()
                    } else {
                        self?.sendOsascriptFallback(title: title, body: body)
                    }
                }
            }
        }
    }

    // MARK: - Osascript Fallback

    private nonisolated func sendOsascriptFallback(title: String, body: String) {
        let safeTitle = title
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let safeBody = body
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        display notification "\(safeBody)" with title "\(safeTitle)" sound name "Glass"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }

    // MARK: - Terminal Activation

    /// Activate the first available terminal app (iTerm2 > Terminal.app).
    private func activateTerminal() {
        let workspace = NSWorkspace.shared
        for bundleID in terminalBundleIDs {
            if let appURL = workspace.urlForApplication(withBundleIdentifier: bundleID) {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                workspace.openApplication(at: appURL, configuration: config)
                return
            }
        }
    }

    func focusTerminal() {
        activateTerminal()
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationManager: UNUserNotificationCenterDelegate {

    /// Show notification even when app is in foreground (status bar app is always "foreground").
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Handle notification click — activate terminal.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else {
            return
        }
        await MainActor.run {
            activateTerminal()
        }
    }
}
