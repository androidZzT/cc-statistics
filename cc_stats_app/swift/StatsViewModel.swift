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
    @Published var rateLimitData: UsageAPI.UsageData?

    enum StatsTab: String, CaseIterable {
        case claudeCode = "Claude Code"
        case cursor = "Cursor"
    }

    /// Filter 阶段的计算结果（不含 projects，projects 在 loadData 中独立加载）
    struct FilterResult {
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

    // MARK: - Cache
    // 缓存已解析的全量 sessions，避免 filter 切换时重复磁盘 IO。
    // 仅当 source 或 project 变更时才清除。
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

    // MARK: - Public API

    /// 完整刷新：磁盘加载 + 内存筛选
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

    /// 切换时间筛选器。
    /// 如果缓存存在，走快速路径（纯内存），否则走完整刷新。
    func setTimeFilter(_ filter: TimeFilter) {
        timeFilter = filter
        if !cachedSessions.isEmpty {
            refreshTask?.cancel()
            refreshTask = Task {
                await applyFilterAndUpdate()
            }
        } else {
            refresh()
        }
    }

    func toggleConversationPanel() {
        showConversationPanel.toggle()
    }

    // MARK: - Core Refresh Pipeline

    /// 完整刷新 = 磁盘加载（重） + 内存筛选（轻）
    private func fullRefresh() async {
        isLoading = true
        defer { isLoading = false }

        await loadData()
        await applyFilterAndUpdate()
    }

    // MARK: - Phase 1: Load Data (disk I/O)

    /// 从磁盘解析 sessions 并缓存。仅在 source/project 变更时执行。
    private func loadData() async {
        let currentSource = selectedSource
        let currentProject = selectedProject

        let needReparse = cachedSessions.isEmpty
            || cachedSource != currentSource
            || cachedProject != currentProject

        guard needReparse else { return }

        let (loadedProjects, sessions) = await Task.detached(priority: .userInitiated) {
            let claudeParser = SessionParser()
            let codexParser = CodexParser()
            let geminiParser = GeminiParser()

            var projects: [ProjectInfo] = []
            var sessions: [Session] = []

            switch currentSource {
            case .all:
                projects = claudeParser.findAllProjects()
                    + codexParser.findAllProjects()
                    + geminiParser.findAllProjects()
                if let project = currentProject {
                    sessions = claudeParser.parseSessions(forProject: project.path)
                        + codexParser.parseSessions(forProject: project.path)
                        + geminiParser.parseSessions(forProject: project.path)
                } else {
                    sessions = claudeParser.parseAllSessions()
                        + codexParser.parseAllSessions()
                        + geminiParser.parseAllSessions()
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
            case .gemini:
                projects = geminiParser.findAllProjects()
                if let project = currentProject {
                    sessions = geminiParser.parseSessions(forProject: project.path)
                } else {
                    sessions = geminiParser.parseAllSessions()
                }
            case .cursor:
                projects = claudeParser.findAllProjects()
                sessions = []
            }
            return (projects, sessions)
        }.value

        cachedProjects = loadedProjects
        cachedSessions = sessions
        cachedSource = currentSource
        cachedProject = currentProject
    }

    // MARK: - Phase 2: Apply Filter (in-memory)

    /// 基于缓存 sessions 做时间过滤、统计分析、日统计。无磁盘 I/O。
    private func applyFilterAndUpdate() async {
        isLoading = true
        defer { isLoading = false }

        let sessions = cachedSessions
        let loadedProjects = cachedProjects
        let currentFilter = timeFilter
        let currentSource = selectedSource

        let result: FilterResult = await Task.detached(priority: .userInitiated) {
            // 按时间范围过滤 sessions
            var filteredSessions = sessions
            if let startDate = currentFilter.startDate {
                filteredSessions = sessions.filter { session in
                    session.messages.contains { msg in
                        if let ts = msg.timestamp { return ts >= startDate }
                        return false
                    }
                }
            }

            let stats = SessionAnalyzer.analyze(
                sessions: filteredSessions,
                since: currentFilter.startDate
            )

            // 会话列表按最近活跃时间排序（不受时间筛选影响）
            let recent = sessions
                .sorted { ($0.endTime ?? .distantPast) > ($1.endTime ?? .distantPast) }
                .prefix(30).map { $0 }

            // 计算当天 token
            let todayStart = Calendar.current.startOfDay(for: Date())
            let todaySessions = sessions.filter { session in
                session.messages.contains { $0.timestamp.map { $0 >= todayStart } ?? false }
            }
            let todayStats = SessionAnalyzer.analyze(
                sessions: todaySessions,
                since: todayStart
            )

            // 14 天日统计（单次分桶算法）
            let daily = Self.computeDailyStats(from: sessions)
            let weeklyCost = daily.suffix(7).reduce(0.0) { $0 + $1.cost }

            return FilterResult(
                stats: stats,
                recentSessions: recent,
                todayTokens: todayStats.totalTokens,
                todayCost: todayStats.estimatedCost,
                todaySessions: todaySessions.count,
                dailyStats: daily,
                weeklyCost: weeklyCost
            )
        }.value

        // 统一赋值，避免 projects 和 stats 分帧更新导致 UI 闪烁
        self.projects = loadedProjects
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

        // 获取速率限制（如果配置了 token）
        fetchRateLimit()

        // 检查用量预警
        checkAlerts(dailyCost: result.todayCost, weeklyCost: result.weeklyCost)
    }

    // MARK: - Daily Stats (Single-Pass Bucketing)

    /// 单次遍历将 sessions 按天分桶，替代 14 次循环遍历。
    /// 复杂度从 O(14 × N × M) 降到 O(N × M + 14 × bucket_size)。
    nonisolated static func computeDailyStats(from sessions: [Session]) -> [DailyStatPoint] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let rangeStart = calendar.date(byAdding: .day, value: -13, to: today) else {
            return []
        }

        // 一次遍历，按天分桶
        var buckets: [Set<Int>] = Array(repeating: [], count: 14)

        for (sessionIdx, session) in sessions.enumerated() {
            var seenDays = Set<Int>()
            for msg in session.messages {
                guard let ts = msg.timestamp, ts >= rangeStart else { continue }
                let dayOffset = calendar.dateComponents([.day], from: rangeStart, to: ts).day ?? 0
                guard dayOffset >= 0 && dayOffset < 14 else { continue }
                seenDays.insert(dayOffset)
            }
            for day in seenDays {
                buckets[day].insert(sessionIdx)
            }
        }

        // 逐桶分析
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd"

        return (0..<14).map { i in
            let dayStart = calendar.date(byAdding: .day, value: i, to: rangeStart)!
            let daySessions = buckets[i].map { sessions[$0] }
            let dayStats = SessionAnalyzer.analyze(sessions: daySessions, since: dayStart)

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

    private func invalidateCache() {
        cachedSessions = []
        cachedProjects = []
        cachedSource = nil
        cachedProject = nil
    }

    private func fetchRateLimit() {
        UsageAPI.fetch { [weak self] data in
            DispatchQueue.main.async {
                self?.rateLimitData = data
            }
        }
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
