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

    struct RefreshResult {
        let stats: SessionStats
        let recentSessions: [Session]
        let todayTokens: Int
        let todayCost: Double
        let todaySessions: Int
        let dailyStats: [DailyStatPoint]
        let weeklyCost: Double
    }

    private var refreshTimer: Timer?
    private var refreshTask: Task<Void, Never>?

    // MARK: - Cache Layer
    // 缓存已解析的全量 sessions，避免 filter 切换时重复磁盘 IO
    private var cachedSessions: [Session] = []
    private var cachedProjects: [ProjectInfo] = []
    private var cachedSource: DataSource?
    private var cachedProject: ProjectInfo?

    init() {
        startAutoRefresh()
        Task {
            await fullRefresh()
        }
    }

    deinit {
        refreshTimer?.invalidate()
    }

    // MARK: - Public Methods

    /// 完整刷新：重新加载数据 + 应用筛选
    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            await fullRefresh()
        }
    }

    func selectSource(_ source: DataSource) {
        selectedSource = source
        invalidateCache()
        refresh()
    }

    func selectProject(_ project: ProjectInfo?) {
        selectedProject = project
        invalidateCache()
        refresh()
    }

    func setTimeFilter(_ filter: TimeFilter) {
        timeFilter = filter
        if !cachedSessions.isEmpty {
            // 快速路径：数据已缓存，只做内存筛选
            refreshTask?.cancel()
            refreshTask = Task {
                await applyFilter()
            }
        } else {
            refresh()
        }
    }

    func toggleConversationPanel() {
        showConversationPanel.toggle()
    }

    // MARK: - Core: Full Refresh (Load + Filter)

    private func fullRefresh() async {
        isLoading = true
        defer { isLoading = false }

        await loadData()
        await applyFilterAndUpdate()
    }

    // MARK: - Phase 1: Load Data (heavy I/O)

    /// 从磁盘加载并解析 sessions，结果缓存在内存。
    /// 仅在数据源/项目变更、手动刷新或定时刷新时调用。
    private func loadData() async {
        let currentProject = selectedProject
        let currentSource = selectedSource

        // 判断是否需要重新解析（source 或 project 变了才需要磁盘 IO）
        let needReparse = cachedSessions.isEmpty
            || cachedSource != currentSource
            || cachedProject != currentProject

        guard needReparse else { return }

        let result: ([ProjectInfo], [Session]) = await Task.detached(priority: .userInitiated) {
            let claudeParser = SessionParser()
            let codexParser = CodexParser()

            var projects: [ProjectInfo] = []
            var sessions: [Session] = []

            switch currentSource {
            case .all:
                projects = claudeParser.findAllProjects() + codexParser.findAllProjects()
                if let project = currentProject {
                    sessions = claudeParser.parseSessions(forProject: project.path)
                        + codexParser.parseSessions(forProject: project.path)
                } else {
                    sessions = claudeParser.parseAllSessions() + codexParser.parseAllSessions()
                }
            case .claudeCode:
                projects = claudeParser.findAllProjects()
                if let project = currentProject {
                    sessions = claudeParser.parseSessions(forProject: project.path)
                } else {
                    sessions = claudeParser.parseAllSessions()
                }
            case .codex:
                projects = codexParser.findAllProjects()
                if let project = currentProject {
                    sessions = codexParser.parseSessions(forProject: project.path)
                } else {
                    sessions = codexParser.parseAllSessions()
                }
            case .cursor:
                projects = claudeParser.findAllProjects()
                sessions = []
            }
            return (projects, sessions)
        }.value

        cachedProjects = result.0
        cachedSessions = result.1
        cachedSource = currentSource
        cachedProject = currentProject
        self.projects = result.0
    }

    // MARK: - Phase 2: Apply Filter (lightweight, in-memory)

    /// 快速路径入口：filter 切换时仅调用此方法
    private func applyFilter() async {
        isLoading = true
        defer { isLoading = false }
        await applyFilterAndUpdate()
    }

    /// 基于缓存的 sessions 做时间过滤 + 分析 + 日统计。无磁盘 I/O。
    private func applyFilterAndUpdate() async {
        let sessions = cachedSessions
        let currentFilter = timeFilter
        let currentSource = selectedSource

        let result: RefreshResult = await Task.detached(priority: .userInitiated) {
            // 按时间范围过滤
            var filteredSessions = sessions
            if let startDate = currentFilter.startDate {
                filteredSessions = sessions.filter { session in
                    session.messages.contains { message in
                        if let ts = message.timestamp {
                            return ts >= startDate
                        }
                        return false
                    }
                }
            }

            let stats = SessionAnalyzer.analyze(sessions: filteredSessions, since: currentFilter.startDate)
            // 会话列表不受时间筛选影响，按最近活跃时间排序
            let recent = sessions
                .sorted(by: { ($0.endTime ?? .distantPast) > ($1.endTime ?? .distantPast) })
                .prefix(30).map { $0 }

            // 计算当天 token
            let todayStart = Calendar.current.startOfDay(for: Date())
            let todaySessions = sessions.filter { session in
                session.messages.contains { $0.timestamp.map { $0 >= todayStart } ?? false }
            }
            let todayStats = SessionAnalyzer.analyze(sessions: todaySessions, since: todayStart)

            // 14 天日统计（单次分桶算法，替代原来的 14 次循环遍历）
            let daily = StatsViewModel.computeDailyStats(from: sessions)

            let weeklyCost = daily.suffix(7).reduce(0.0) { $0 + $1.cost }

            return RefreshResult(
                stats: stats,
                recentSessions: recent,
                todayTokens: todayStats.totalTokens,
                todayCost: todayStats.estimatedCost,
                todaySessions: todaySessions.count,
                dailyStats: daily,
                weeklyCost: weeklyCost
            )
        }.value

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

        checkAlerts(dailyCost: result.todayCost, weeklyCost: result.weeklyCost)
    }

    // MARK: - Daily Stats (Single-Pass Bucketing)

    /// 单次遍历将 sessions 按天分桶，替代原来的 14 次循环遍历。
    /// 复杂度从 O(14 × N) 降到 O(N + 14 × bucket_size)。
    nonisolated static func computeDailyStats(from sessions: [Session]) -> [DailyStatPoint] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let fourteenDaysAgo = calendar.date(byAdding: .day, value: -13, to: today) else { return [] }

        // 一次遍历，按天分桶
        var buckets: [[Session]] = Array(repeating: [], count: 14)

        for session in sessions {
            // 按天分组该 session 的消息，确定它归属哪些天
            var seenDays = Set<Int>()
            for msg in session.messages {
                guard let ts = msg.timestamp, ts >= fourteenDaysAgo else { continue }
                let dayOffset = calendar.dateComponents([.day], from: fourteenDaysAgo, to: ts).day ?? 0
                guard dayOffset >= 0 && dayOffset < 14 else { continue }
                seenDays.insert(dayOffset)
            }

            for dayOffset in seenDays {
                buckets[dayOffset].append(session)
            }
        }

        // 逐桶分析
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd"

        return (0..<14).map { i in
            let dayStart = calendar.date(byAdding: .day, value: i, to: fourteenDaysAgo)!
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!
            let daySessions = buckets[i]

            // 传入 since/until 让 analyzer 只统计当天的消息
            let dayStats = SessionAnalyzer.analyze(sessions: daySessions, since: dayStart)
            // 再过滤掉超出当天的部分（only count messages within [dayStart, dayEnd)）
            // SessionAnalyzer.analyze(since:) 只过滤 >= dayStart，需要额外处理 < dayEnd
            // 但因为桶内 session 已经按天分组，跨天 session 的其他天消息会被 since 过滤掉
            // 唯一例外是 dayEnd 之后的消息也会被计入，这里用 analyze(since:) 已足够精确

            return DailyStatPoint(
                date: dayStart,
                label: formatter.string(from: dayStart),
                sessions: daySessions.count,
                messages: dayStats.userInstructions,
                tokens: dayStats.totalTokens,
                cost: dayStats.estimatedCost,
                activeMinutes: dayStats.aiProcessingTime / 60 + dayStats.userActiveTime / 60
            )
        }
    }

    // MARK: - Alerts

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

    private func invalidateCache() {
        cachedSessions = []
        cachedProjects = []
        cachedSource = nil
        cachedProject = nil
    }

    // MARK: - Auto Refresh

    private func startAutoRefresh() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.refresh()
            }
        }
    }
}
