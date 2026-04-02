import Foundation

// MARK: - BurnAlertLevel

enum BurnAlertLevel: Int, Comparable {
    case none = 0
    case info = 1
    case warning = 2
    case critical = 3

    static func < (lhs: BurnAlertLevel, rhs: BurnAlertLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - UsageBurnMonitor

/// Monitors API usage burn rate and triggers alerts when consumption is too fast.
/// Independent of StatsViewModel — receives data via `process(data:)`.
@MainActor
final class UsageBurnMonitor {

    // MARK: - Public State

    private(set) var alertLevel5h: BurnAlertLevel = .none
    private(set) var alertLevel7d: BurnAlertLevel = .none

    // MARK: - Configuration

    private enum Config {
        // Low-usage filter thresholds
        static let lowUsage5h: Double = 15
        static let lowUsage7d: Double = 10

        // INFO burn ratio thresholds
        static let infoBurnRatio5h: Double = 1.3
        static let infoBurnRatio7d: Double = 1.2
        // INFO minimum usage to show (same as low-usage filter)
        static let infoMinUsage5h: Double = 30
        static let infoMinUsage7d: Double = 10

        // CRITICAL burn ratio thresholds
        static let criticalBurnRatio5h: Double = 3.0
        static let criticalBurnRatio7d: Double = 2.0
        // CRITICAL high-usage + low-elapsed threshold
        static let criticalHighUsage: Double = 80
        static let criticalLowElapsed: Double = 50

        // Sliding window size for smoothing
        static let slidingWindowSize = 3
        // Debounce: consecutive samples above threshold required
        static let debounceCount = 2
    }

    // MARK: - Window State

    private struct WindowState {
        var burnRatioHistory: [Double] = []
        var lastNotifiedLevel: BurnAlertLevel = .none

        /// Add a burn ratio sample and return the smoothed (average) value.
        mutating func addSample(_ ratio: Double) -> Double {
            burnRatioHistory.append(ratio)
            if burnRatioHistory.count > Config.slidingWindowSize {
                burnRatioHistory.removeFirst()
            }
            return burnRatioHistory.reduce(0, +) / Double(burnRatioHistory.count)
        }

        /// Returns true if the last N smoothed samples (debounceCount) all exceeded the threshold.
        func isDebounced(threshold: Double) -> Bool {
            guard burnRatioHistory.count >= Config.debounceCount else { return false }
            let recentSamples = burnRatioHistory.suffix(Config.debounceCount)
            let avg1 = recentSamples.dropLast().reduce(0, +) / Double(max(recentSamples.count - 1, 1))
            let avg2 = recentSamples.reduce(0, +) / Double(recentSamples.count)
            return avg1 > threshold && avg2 > threshold
        }
    }

    private var state5h = WindowState()
    private var state7d = WindowState()

    // MARK: - Public API

    /// Process usage data and update alert levels. Call on MainActor.
    func process(data: UsageAPI.UsageData) {
        alertLevel5h = evaluate5h(data: data)
        alertLevel7d = evaluate7d(data: data)
    }

    // MARK: - Evaluation

    private func evaluate5h(data: UsageAPI.UsageData) -> BurnAlertLevel {
        let usagePct = Double(data.fiveHourPercent)

        // Low-usage filter
        guard usagePct >= Config.lowUsage5h else {
            _ = state5h.addSample(0)
            maybeNotify(level: .none, window: .fiveHour, state: &state5h, data: data)
            return .none
        }

        let windowDuration: TimeInterval = 5 * 3600 // 5 hours in seconds
        let elapsed = computeElapsed(resetsAt: data.fiveHourResetsAt, windowDuration: windowDuration)
        let metrics = computeMetrics(usagePct: usagePct, elapsed: elapsed, windowDuration: windowDuration)

        let smoothedRatio = state5h.addSample(metrics.burnRatio)
        let level = classifyLevel(
            smoothedRatio: smoothedRatio,
            usagePct: usagePct,
            elapsedPct: metrics.elapsedPct,
            projectedEnd: metrics.projectedEnd,
            etaMinutes: metrics.etaMinutes,
            remainingMinutes: metrics.remainingMinutes,
            infoBurnThreshold: Config.infoBurnRatio5h,
            criticalBurnThreshold: Config.criticalBurnRatio5h,
            infoMinUsage: Config.infoMinUsage5h
        )

        maybeNotify(level: level, window: .fiveHour, state: &state5h, data: data)
        return level
    }

    private func evaluate7d(data: UsageAPI.UsageData) -> BurnAlertLevel {
        let usagePct = Double(data.sevenDayPercent)

        // Low-usage filter
        guard usagePct >= Config.lowUsage7d else {
            _ = state7d.addSample(0)
            maybeNotify(level: .none, window: .sevenDay, state: &state7d, data: data)
            return .none
        }

        let windowDuration: TimeInterval = 7 * 24 * 3600 // 7 days in seconds
        let elapsed = computeElapsed(resetsAt: data.sevenDayResetsAt, windowDuration: windowDuration)
        let metrics = computeMetrics(usagePct: usagePct, elapsed: elapsed, windowDuration: windowDuration)

        let smoothedRatio = state7d.addSample(metrics.burnRatio)
        let level = classifyLevel(
            smoothedRatio: smoothedRatio,
            usagePct: usagePct,
            elapsedPct: metrics.elapsedPct,
            projectedEnd: metrics.projectedEnd,
            etaMinutes: metrics.etaMinutes,
            remainingMinutes: metrics.remainingMinutes,
            infoBurnThreshold: Config.infoBurnRatio7d,
            criticalBurnThreshold: Config.criticalBurnRatio7d,
            infoMinUsage: Config.infoMinUsage7d
        )

        maybeNotify(level: level, window: .sevenDay, state: &state7d, data: data)
        return level
    }

    // MARK: - Metrics Computation

    private struct BurnMetrics {
        let burnRatio: Double
        let elapsedPct: Double
        let etaMinutes: Double
        let remainingMinutes: Double
        let projectedEnd: Double
    }

    private func computeElapsed(resetsAt: Date?, windowDuration: TimeInterval) -> TimeInterval {
        guard let resetsAt = resetsAt else { return windowDuration / 2 } // default: assume halfway
        let remaining = max(resetsAt.timeIntervalSinceNow, 0)
        return windowDuration - remaining
    }

    private func computeMetrics(usagePct: Double, elapsed: TimeInterval, windowDuration: TimeInterval) -> BurnMetrics {
        let elapsedPct = elapsed / windowDuration * 100
        let burnRatio = usagePct / max(elapsedPct, 1)

        let elapsedMinutes = max(elapsed / 60, 1)
        let burnRatePerMin = usagePct / elapsedMinutes
        let etaMinutes = burnRatePerMin > 0 ? (100 - usagePct) / burnRatePerMin : Double.infinity

        let remainingMinutes = max((windowDuration - elapsed) / 60, 0)
        let projectedEnd = usagePct + burnRatePerMin * remainingMinutes

        return BurnMetrics(
            burnRatio: burnRatio,
            elapsedPct: elapsedPct,
            etaMinutes: etaMinutes,
            remainingMinutes: remainingMinutes,
            projectedEnd: projectedEnd
        )
    }

    private func classifyLevel(
        smoothedRatio: Double,
        usagePct: Double,
        elapsedPct: Double,
        projectedEnd: Double,
        etaMinutes: Double,
        remainingMinutes: Double,
        infoBurnThreshold: Double,
        criticalBurnThreshold: Double,
        infoMinUsage: Double
    ) -> BurnAlertLevel {
        // CRITICAL: extremely fast burn or high usage early in window
        if smoothedRatio > criticalBurnThreshold {
            return .critical
        }
        if usagePct > Config.criticalHighUsage && elapsedPct < Config.criticalLowElapsed {
            return .critical
        }

        // WARNING: projected to exceed limit before window resets
        if projectedEnd > 100 && etaMinutes < remainingMinutes {
            return .warning
        }

        // INFO: burning faster than sustainable, with meaningful usage
        if smoothedRatio > infoBurnThreshold && usagePct > infoMinUsage {
            return .info
        }

        return .none
    }

    // MARK: - Notification

    private enum WindowType: String {
        case fiveHour = "5h"
        case sevenDay = "7d"

        var windowLabel: String {
            switch self {
            case .fiveHour: return "5h"
            case .sevenDay: return "7d"
            }
        }

        var windowDurationHours: Double {
            switch self {
            case .fiveHour: return 5
            case .sevenDay: return 168 // 7 * 24
            }
        }
    }

    private func maybeNotify(level: BurnAlertLevel, window: WindowType, state: inout WindowState, data: UsageAPI.UsageData) {
        // Only send system notifications for WARNING and CRITICAL
        guard level >= .warning else {
            state.lastNotifiedLevel = level
            return
        }

        // Debounce: require consecutive samples above threshold
        let threshold: Double
        switch window {
        case .fiveHour: threshold = level == .critical ? Config.criticalBurnRatio5h : Config.infoBurnRatio5h
        case .sevenDay: threshold = level == .critical ? Config.criticalBurnRatio7d : Config.infoBurnRatio7d
        }
        guard state.isDebounced(threshold: threshold) else { return }

        // Don't re-notify for the same level
        guard level != state.lastNotifiedLevel else { return }
        state.lastNotifiedLevel = level

        let (usagePct, resetsAt): (Int, Date?) = {
            switch window {
            case .fiveHour: return (data.fiveHourPercent, data.fiveHourResetsAt)
            case .sevenDay: return (data.sevenDayPercent, data.sevenDayResetsAt)
            }
        }()

        let windowDuration: TimeInterval = window.windowDurationHours * 3600
        let elapsed = computeElapsed(resetsAt: resetsAt, windowDuration: windowDuration)
        let metrics = computeMetrics(usagePct: Double(usagePct), elapsed: elapsed, windowDuration: windowDuration)

        let elapsedHours = elapsed / 3600
        let etaStr: String
        if metrics.etaMinutes < 60 {
            etaStr = String(format: "%.0fmin", metrics.etaMinutes)
        } else {
            etaStr = String(format: "%.1fh", metrics.etaMinutes / 60)
        }
        let remainStr = String(format: "%.1fh", metrics.remainingMinutes / 60)

        let icon = level == .critical ? "🔴" : "⚠️"
        let levelStr = level == .critical ? "Critical" : "Warning"
        let title = "\(icon) \(window.windowLabel) Usage \(levelStr)"

        let body = """
        Current: \(usagePct)% | Elapsed: \(String(format: "%.1f", elapsedHours))h / \(String(format: "%.0f", window.windowDurationHours))h (\(String(format: "%.0f", metrics.elapsedPct))%)
        Burn ratio: \(String(format: "%.1f", metrics.burnRatio))x (normal: 1.0x)
        Est. limit hit in \(etaStr), window resets in \(remainStr)
        Tip: Reduce agent concurrency or wait for reset
        """

        NotificationManager.shared.send(title: title, body: body)
    }
}
