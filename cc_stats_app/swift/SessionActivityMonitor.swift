import Foundation

// MARK: - Session Activity State

enum SessionActivityState: String, Equatable {
    case active
    case waitingApproval
    case idle
    case sleeping
}

// MARK: - Session Activity Snapshot

struct SessionActivitySnapshot: Equatable {
    let state: SessionActivityState
    let event: String
    let timestamp: TimeInterval?
    let bridgeEnabled: Bool
    let approvalId: String?
    let toolName: String?
    let action: String?
}

// MARK: - Session Activity Monitor

/// Monitors Claude Code activity by reading a state file written by hook scripts.
///
/// Hook script (`hooks/ccstats-hook.js`) writes `~/.cc-stats/activity-state.json`
/// on every Claude Code event with `{ state, event, timestamp }`.
///
/// This monitor polls that file and derives:
/// - waitingApproval: PermissionRequest within approval timeout window
/// - active:   hook wrote "active" within the last 3 minutes
/// - idle:     hook wrote "idle", or "active" older than 3 min but within 10 min
/// - sleeping: no state update for > 10 minutes
final class SessionActivityMonitor {

    // MARK: - Configuration

    struct Thresholds {
        // Claude can spend well over 30s thinking before the next tool event lands.
        // A wider window keeps the island visible through those quiet stretches.
        var activeTimeout: TimeInterval = 180
        var approvalTimeout: TimeInterval = 300
        var sleepingTimeout: TimeInterval = 600
        var pollInterval: TimeInterval = 3
    }

    // MARK: - Public

    let thresholds: Thresholds
    private(set) var currentState: SessionActivityState = .idle
    var onStateChange: ((SessionActivityState) -> Void)?
    var onSnapshotChange: ((SessionActivitySnapshot) -> Void)?

    // MARK: - Internal

    private let stateFilePath: String
    private var pollTimer: Timer?
    private var lastSnapshot: SessionActivitySnapshot?

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
        hookEvent: String?,
        hookTimestamp: TimeInterval?,
        now: TimeInterval,
        thresholds: Thresholds
    ) -> SessionActivityState {
        guard let ts = hookTimestamp else { return .sleeping }

        let elapsed = now - ts / 1000.0  // timestamp is in ms

        if hookEvent == "PermissionRequest", elapsed <= thresholds.approvalTimeout {
            return .waitingApproval
        }

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
        var hookEvent: String?
        var hookTimestamp: TimeInterval?
        var bridgeEnabled = false
        var approvalId: String?
        var toolName: String?
        var action: String?

        if let data = FileManager.default.contents(atPath: stateFilePath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            hookState = json["state"] as? String
            hookEvent = json["event"] as? String
            hookTimestamp = json["timestamp"] as? TimeInterval
            bridgeEnabled = json["bridge_enabled"] as? Bool ?? false
            approvalId = json["approval_id"] as? String
            toolName = json["tool_name"] as? String
            action = json["action"] as? String
        }

        let newState = Self.evaluateState(
            hookState: hookState,
            hookEvent: hookEvent,
            hookTimestamp: hookTimestamp,
            now: Date().timeIntervalSince1970,
            thresholds: thresholds
        )

        let snapshot = SessionActivitySnapshot(
            state: newState,
            event: hookEvent ?? "",
            timestamp: hookTimestamp,
            bridgeEnabled: bridgeEnabled,
            approvalId: approvalId,
            toolName: toolName,
            action: action
        )
        if snapshot != lastSnapshot {
            lastSnapshot = snapshot
            onSnapshotChange?(snapshot)
        }

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
