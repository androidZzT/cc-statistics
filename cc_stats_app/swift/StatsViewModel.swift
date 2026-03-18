import Foundation
import SwiftUI
import Combine

// MARK: - TimeFilter

enum TimeFilter: String, CaseIterable, Identifiable {
    case today
    case week
    case month
    case all

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .today: return L10n.today
        case .week: return L10n.week
        case .month: return L10n.month
        case .all: return L10n.allTime
        }
    }

    var startDate: Date? {
        let calendar = Calendar.current
        let now = Date()
        switch self {
        case .today:
            return calendar.startOfDay(for: now)
        case .week:
            return calendar.date(byAdding: .day, value: -7, to: now)
        case .month:
            return calendar.date(byAdding: .month, value: -1, to: now)
        case .all:
            return nil
        }
    }
}

// MARK: - StatsViewModel

@MainActor
final class StatsViewModel: ObservableObject {
    @Published var projects: [ProjectInfo] = []
    @Published var selectedProject: ProjectInfo?
    @Published var selectedSource: DataSource = .all
    @Published var timeFilter: TimeFilter = .today
    @Published var stats: SessionStats?
    @Published var isLoading = false
    @Published var lastRefreshed: Date?
    @Published var recentSessions: [Session] = []
    @Published var showConversationPanel: Bool = false
    @Published var cursorStats: CursorStats?
    @Published var activeTab: StatsTab = .claudeCode
    @Published var todayTokens: Int = 0
    @Published var todayCost: Double = 0
    @Published var todaySessions: Int = 0
    @Published var dailyStats: [DailyStatPoint] = []
    @Published var showSettings: Bool = false
    @Published var languageVersion: Int = 0  // 递增以触发 UI 刷新
    @Published var themeMode: String = UserDefaults.standard.string(forKey: "cc_stats_theme") ?? "auto"
    @Published var alertMessages: [String] = []
    @Published var isOverDailyLimit: Bool = false
    @Published var isOverWeeklyLimit: Bool = false

    enum StatsTab: String, CaseIterable {
        case claudeCode = "Claude Code"
        case cursor = "Cursor"
    }

    private var refreshTimer: Timer?
    private var refreshTask: Task<Void, Never>?

    init() {
        startAutoRefresh()
        Task {
            await performRefresh()
        }
    }

    deinit {
        refreshTimer?.invalidate()
    }

    // MARK: - Public Methods

    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            await performRefresh()
        }
    }

    struct RefreshResult {
        let projects: [ProjectInfo]
        let stats: SessionStats
        let recentSessions: [Session]
        let todayTokens: Int
        let todayCost: Double
        let todaySessions: Int
        let dailyStats: [DailyStatPoint]
        let weeklyCost: Double
    }

    func selectSource(_ source: DataSource) {
        selectedSource = source
        activeTab = (source == .cursor) ? .cursor : .claudeCode
        refresh()
    }

    func performRefresh() async {
        isLoading = true
        defer { isLoading = false }

        let currentFilter = timeFilter
        let currentProject = selectedProject
        let currentSource = selectedSource

        let result: RefreshResult = await Task.detached(priority: .userInitiated) {
            let claudeParser = SessionParser()
            let codexParser = CodexParser()

            // 根据 source 获取 projects 和 sessions
            var loadedProjects: [ProjectInfo] = []
            var allSessions: [Session] = []

            switch currentSource {
            case .all:
                loadedProjects = claudeParser.findAllProjects() + codexParser.findAllProjects()
                if let project = currentProject {
                    allSessions = claudeParser.parseSessions(forProject: project.path)
                        + codexParser.parseSessions(forProject: project.path)
                } else {
                    allSessions = claudeParser.parseAllSessions() + codexParser.parseAllSessions()
                }
            case .claudeCode:
                loadedProjects = claudeParser.findAllProjects()
                if let project = currentProject {
                    allSessions = claudeParser.parseSessions(forProject: project.path)
                } else {
                    allSessions = claudeParser.parseAllSessions()
                }
            case .codex:
                loadedProjects = codexParser.findAllProjects()
                if let project = currentProject {
                    allSessions = codexParser.parseSessions(forProject: project.path)
                } else {
                    allSessions = codexParser.parseAllSessions()
                }
            case .cursor:
                // Cursor uses a different parser (CursorParser), sessions handled separately
                loadedProjects = claudeParser.findAllProjects()
                allSessions = []
            }

            // 按时间范围过滤（用于面板展示）
            var filteredSessions = allSessions
            if let startDate = currentFilter.startDate {
                filteredSessions = allSessions.filter { session in
                    session.messages.contains { message in
                        if let ts = message.timestamp {
                            return ts >= startDate
                        }
                        return false
                    }
                }
            }

            let stats = SessionAnalyzer.analyze(sessions: filteredSessions)
            let recent = filteredSessions
                .sorted(by: { ($0.startTime ?? .distantPast) > ($1.startTime ?? .distantPast) })
                .prefix(20).map { $0 }

            // 计算当天 token（从同一批数据中过滤，保证同步）
            let todayStart = Calendar.current.startOfDay(for: Date())
            let todaySessions = allSessions.filter { session in
                session.messages.contains { $0.timestamp.map { $0 >= todayStart } ?? false }
            }
            let todayStats = SessionAnalyzer.analyze(sessions: todaySessions)

            // 每日聚合（最近 14 天）
            let calendar = Calendar.current
            let today = Date()
            var daily: [DailyStatPoint] = []
            let formatter = DateFormatter()
            formatter.dateFormat = "MM/dd"
            for i in (0..<14).reversed() {
                guard let dayStart = calendar.date(byAdding: .day, value: -i, to: calendar.startOfDay(for: today)) else { continue }
                let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!
                let daySessions = allSessions.filter { session in
                    session.messages.contains { msg in
                        guard let ts = msg.timestamp else { return false }
                        return ts >= dayStart && ts < dayEnd
                    }
                }
                let dayStats = SessionAnalyzer.analyze(sessions: daySessions)
                daily.append(DailyStatPoint(
                    date: dayStart,
                    label: formatter.string(from: dayStart),
                    sessions: daySessions.count,
                    messages: dayStats.userInstructions,
                    tokens: dayStats.totalTokens,
                    cost: dayStats.estimatedCost,
                    activeMinutes: dayStats.aiProcessingTime / 60 + dayStats.userActiveTime / 60
                ))
            }

            // 计算最近 7 天费用
            let weeklyCost = daily.suffix(7).reduce(0.0) { $0 + $1.cost }

            return RefreshResult(
                projects: loadedProjects,
                stats: stats,
                recentSessions: recent,
                todayTokens: todayStats.totalTokens,
                todayCost: todayStats.estimatedCost,
                todaySessions: todaySessions.count,
                dailyStats: daily,
                weeklyCost: weeklyCost
            )
        }.value

        self.projects = result.projects
        self.stats = result.stats
        self.recentSessions = result.recentSessions
        self.todayTokens = result.todayTokens
        self.todayCost = result.todayCost
        self.todaySessions = result.todaySessions
        self.dailyStats = result.dailyStats

        // Parse Cursor stats only when relevant
        if currentSource == .cursor || currentSource == .all {
            let cursorSince = currentFilter.startDate
            let cursorResult: CursorStats = await Task.detached(priority: .userInitiated) {
                CursorParser.parse(since: cursorSince)
            }.value
            self.cursorStats = cursorResult
        } else {
            self.cursorStats = nil
        }

        self.lastRefreshed = Date()

        // 检查用量预警
        checkAlerts(dailyCost: result.todayCost, weeklyCost: result.weeklyCost)
    }

    private func checkAlerts(dailyCost: Double, weeklyCost: Double) {
        let dailyLimit = UserDefaults.standard.double(forKey: "cc_stats_daily_cost_limit")
        let weeklyLimit = UserDefaults.standard.double(forKey: "cc_stats_weekly_cost_limit")

        var alerts: [String] = []
        let wasDailyOver = isOverDailyLimit
        let wasWeeklyOver = isOverWeeklyLimit

        if dailyLimit > 0 && dailyCost > dailyLimit {
            isOverDailyLimit = true
            let msg = L10n.alertExceeded(
                CostEstimator.formatCost(dailyCost),
                CostEstimator.formatCost(dailyLimit) + " " + L10n.alertDaily
            )
            alerts.append(msg)
            // 刚超限时弹通知
            if !wasDailyOver {
                sendSystemNotification(title: L10n.tokenAlert, body: msg)
            }
        } else {
            isOverDailyLimit = false
        }

        if weeklyLimit > 0 && weeklyCost > weeklyLimit {
            isOverWeeklyLimit = true
            let msg = L10n.alertExceeded(
                CostEstimator.formatCost(weeklyCost),
                CostEstimator.formatCost(weeklyLimit) + " " + L10n.alertWeekly
            )
            alerts.append(msg)
            if !wasWeeklyOver {
                sendSystemNotification(title: L10n.tokenAlert, body: msg)
            }
        } else {
            isOverWeeklyLimit = false
        }

        alertMessages = alerts
    }

    private func sendSystemNotification(title: String, body: String) {
        let script = """
        display notification "\(body)" with title "\(title)" sound name "Glass"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }

    func selectProject(_ project: ProjectInfo?) {
        selectedProject = project
        refresh()
    }

    func setTimeFilter(_ filter: TimeFilter) {
        timeFilter = filter
        refresh()
    }

    func toggleConversationPanel() {
        showConversationPanel.toggle()
    }

    // MARK: - Private Methods

    private func startAutoRefresh() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.refresh()
            }
        }
    }
}
