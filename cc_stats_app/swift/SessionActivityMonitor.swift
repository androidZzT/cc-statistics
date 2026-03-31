import Foundation

// MARK: - Session Activity State

enum SessionActivityState: String, Equatable {
    case active
    case idle
    case sleeping
}

// MARK: - Session Activity Monitor

/// Monitors Claude Code activity by reading a state file written by hook scripts.
///
/// Hook script (`hooks/ccstats-hook.js`) writes `~/.cc-stats/activity-state.json`
/// on every Claude Code event with `{ state, event, timestamp }`.
///
/// This monitor polls that file and derives:
/// - active:   hook wrote "active" within the last 30 seconds
/// - idle:     hook wrote "idle", or "active" older than 30s but within 10 min
/// - sleeping: no state update for > 10 minutes
final class SessionActivityMonitor {

    // MARK: - Configuration

    struct Thresholds {
        var activeTimeout: TimeInterval = 30
        var sleepingTimeout: TimeInterval = 600
        var pollInterval: TimeInterval = 3
    }

    // MARK: - Public

    let thresholds: Thresholds
    private(set) var currentState: SessionActivityState = .idle
    var onStateChange: ((SessionActivityState) -> Void)?

    // MARK: - Internal

    private let stateFilePath: String
    private var pollTimer: Timer?

    // MARK: - Init

    init(thresholds: Thresholds = Thresholds()) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.stateFilePath = (home as NSString).appendingPathComponent(".cc-stats/activity-state.json")
        self.thresholds = thresholds
    }

    deinit { stop() }

    // MARK: - Lifecycle

    func start() {
        pollStateFile()
        startPollTimer()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - State Evaluation

    static func evaluateState(
        hookState: String?,
        hookTimestamp: TimeInterval?,
        now: TimeInterval,
        thresholds: Thresholds
    ) -> SessionActivityState {
        guard let ts = hookTimestamp else { return .sleeping }

        let elapsed = now - ts / 1000.0  // timestamp is in ms

        if hookState == "active" && elapsed <= thresholds.activeTimeout {
            return .active
        } else if elapsed <= thresholds.sleepingTimeout {
            return .idle
        } else {
            return .sleeping
        }
    }

    // MARK: - File Polling

    private func startPollTimer() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(
            withTimeInterval: thresholds.pollInterval,
            repeats: true
        ) { [weak self] _ in
            self?.pollStateFile()
        }
    }

    private func pollStateFile() {
        var hookState: String?
        var hookTimestamp: TimeInterval?

        if let data = FileManager.default.contents(atPath: stateFilePath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            hookState = json["state"] as? String
            hookTimestamp = json["timestamp"] as? TimeInterval
        }

        let newState = Self.evaluateState(
            hookState: hookState,
            hookTimestamp: hookTimestamp,
            now: Date().timeIntervalSince1970,
            thresholds: thresholds
        )

        if newState != currentState {
            currentState = newState
            onStateChange?(newState)
        }
    }

    // MARK: - Testing

    func _testForceEvaluate() {
        pollStateFile()
    }
}
