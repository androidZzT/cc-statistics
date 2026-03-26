import Foundation
import SwiftUI
import Combine
import UserNotifications

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

    /// 面板是否可见。不可见时暂停定时刷新，降低 CPU 占用。
    var isPanelVisible: Bool = false {
        didSet {
            guard isPanelVisible != oldValue else { return }
            if isPanelVisible {
                startAutoRefresh()
                refresh()
            } else {
                pauseAutoRefresh()
            }
        }
    }

    // MARK: - Cache
    // 缓存已解析的全量 sessions，避免 filter 切换时重复磁盘 IO。
    // 仅当 source 或 project 变更时才清除。
    private var cachedSessions: [Session] = []
    private var cachedProjects: [ProjectInfo] = []
    private var cachedSource: DataSource?
    private var cachedProject: ProjectInfo?

    // MARK: - Version Update
    @Published var updateAvailable: String?  // 新版本号（nil = 无更新）

    init() {
        // 初始加载数据（状态栏需要），但不启动定时刷新。
        // 定时刷新仅在面板可见时运行（通过 isPanelVisible didSet 控制）。
        Task {
            await fullRefresh()
        }
        startVersionCheck()
    }

    deinit {
        refreshTimer?.invalidate()
        versionCheckTimer?.invalidate()
    }

    // MARK: - Public API

    /// 完整刷新：磁盘加载 + 内存筛选
    func refresh() {
        refreshTask?.cancel()
        invalidateCache()
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
    /// isLoading 由 applyFilterAndUpdate 统一管理。
    private func fullRefresh() async {
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

            // 14 天日统计（单次分桶算法，today 是最后一个桶）
            let daily = Self.computeDailyStats(from: sessions)
            let todayPoint = daily.last
            let weeklyCost = daily.suffix(7).reduce(0.0) { $0 + $1.cost }

            return FilterResult(
                stats: stats,
                recentSessions: recent,
                todayTokens: todayPoint?.tokens ?? 0,
                todayCost: todayPoint?.cost ?? 0,
                todaySessions: todayPoint?.sessions ?? 0,
                dailyStats: daily,
                weeklyCost: weeklyCost
            )
        }.value

        // 仅在值变化时赋值，避免无效的 SwiftUI 重渲染
        if self.projects != loadedProjects { self.projects = loadedProjects }
        if self.stats != result.stats { self.stats = result.stats }
        if self.recentSessions != result.recentSessions { self.recentSessions = result.recentSessions }
        if self.todayTokens != result.todayTokens { self.todayTokens = result.todayTokens }
        if self.todayCost != result.todayCost { self.todayCost = result.todayCost }
        if self.todaySessions != result.todaySessions { self.todaySessions = result.todaySessions }
        if self.dailyStats != result.dailyStats { self.dailyStats = result.dailyStats }

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
    /// 最后一个桶（index 13）是今天的数据，可直接用于 todayTokens/todayCost。
    nonisolated static func computeDailyStats(from sessions: [Session]) -> [DailyStatPoint] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let rangeStart = calendar.date(byAdding: .day, value: -13, to: today) else {
            return []
        }

        // 一次遍历，按天分桶
        var buckets: [[Session]] = Array(repeating: [], count: 14)

        for session in sessions {
            var seenDays = Set<Int>()
            for msg in session.messages {
                guard let ts = msg.timestamp, ts >= rangeStart else { continue }
                let dayOffset = calendar.dateComponents([.day], from: rangeStart, to: ts).day ?? 0
                guard dayOffset >= 0 && dayOffset < 14 else { continue }
                seenDays.insert(dayOffset)
            }
            for day in seenDays {
                buckets[day].append(session)
            }
        }

        // 逐桶分析
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd"

        return (0..<14).map { i in
            let dayStart = calendar.date(byAdding: .day, value: i, to: rangeStart)!
            let daySessions = buckets[i]
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
        NotificationManager.shared.send(title: title, body: body)
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
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.refresh()
            }
        }
    }

    private func pauseAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Version Check

    private var versionCheckTimer: Timer?
    private var hasNotifiedVersion: String?  // 已通知过的版本，避免重复通知

    private func startVersionCheck() {
        // 首次延迟 30 秒检查（让 app 先完成启动）
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            self?.performVersionCheck()
        }
        // 之后每 4 小时检查
        versionCheckTimer = Timer.scheduledTimer(withTimeInterval: 4 * 3600, repeats: true) { [weak self] _ in
            self?.performVersionCheck()
        }
    }

    private func performVersionCheck() {
        Task.detached(priority: .utility) {
            guard let latestVersion = Self.fetchLatestVersionFromPyPI() else { return }
            let currentVersion = Self.readCurrentVersion()
            guard Self.isNewer(remote: latestVersion, local: currentVersion) else { return }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.updateAvailable = latestVersion

                // 仅在首次发现新版本时发送系统通知
                if self.hasNotifiedVersion != latestVersion {
                    self.hasNotifiedVersion = latestVersion
                    self.sendSystemNotification(
                        title: "cc-statistics 更新可用",
                        body: "cc-statistics v\(latestVersion) 已发布，运行 pip install --upgrade cc-statistics 更新"
                    )
                }
            }
        }
    }

    /// 从 PyPI 获取最新版本号
    nonisolated private static func fetchLatestVersionFromPyPI() -> String? {
        guard let url = URL(string: "https://pypi.org/pypi/cc-statistics/json") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let semaphore = DispatchSemaphore(value: 0)
        var result: String?

        let task = URLSession.shared.dataTask(with: request) { data, _, error in
            defer { semaphore.signal() }
            guard error == nil, let data = data else { return }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let info = json["info"] as? [String: Any],
                  let version = info["version"] as? String else { return }
            result = version
        }
        task.resume()
        semaphore.wait()
        return result
    }

    /// 从 SettingsView 或 fallback 读取当前版本
    nonisolated private static func readCurrentVersion() -> String {
        // 尝试从 version_cache 或已知路径读取
        let home = FileManager.default.homeDirectoryForCurrentUser
        let versionFile = home.appendingPathComponent(".cc-stats/current_version")
        if let version = try? String(contentsOf: versionFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !version.isEmpty {
            return version
        }
        // Fallback: 从 __init__.py 读取 __version__
        let possiblePaths = [
            "/usr/local/lib/python3.12/site-packages/cc_stats/__init__.py",
            "/usr/local/lib/python3.11/site-packages/cc_stats/__init__.py",
            "/opt/homebrew/lib/python3.12/site-packages/cc_stats/__init__.py",
            "/opt/homebrew/lib/python3.11/site-packages/cc_stats/__init__.py",
        ]
        for path in possiblePaths {
            if let content = try? String(contentsOfFile: path, encoding: .utf8) {
                for line in content.components(separatedBy: "\n") {
                    if line.contains("__version__") && line.contains("=") {
                        let parts = line.components(separatedBy: "\"")
                        if parts.count >= 2 { return parts[1] }
                        let squoteParts = line.components(separatedBy: "'")
                        if squoteParts.count >= 2 { return squoteParts[1] }
                    }
                }
            }
        }
        // 最终 fallback: 用 python3 -c 获取
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", "from cc_stats import __version__; print(__version__)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        if let _ = try? process.run() {
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let version = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !version.isEmpty {
                return version
            }
        }
        return "0.0.0"
    }

    /// 比较版本号：remote > local ?
    nonisolated private static func isNewer(remote: String, local: String) -> Bool {
        let remoteParts = remote.split(separator: ".").compactMap { Int($0) }
        let localParts = local.split(separator: ".").compactMap { Int($0) }
        let maxLen = max(remoteParts.count, localParts.count)
        for i in 0..<maxLen {
            let r = i < remoteParts.count ? remoteParts[i] : 0
            let l = i < localParts.count ? localParts[i] : 0
            if r > l { return true }
            if r < l { return false }
        }
        return false
    }
}
