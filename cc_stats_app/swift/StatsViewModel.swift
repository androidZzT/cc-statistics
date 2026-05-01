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
    @Published var conversationSessions: [Session] = []
    @Published var isConversationLoading: Bool = false
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
    @Published var isTokenExpired: Bool = false
    @Published var burnAlertLevel5h: BurnAlertLevel = .none
    @Published var burnAlertLevel7d: BurnAlertLevel = .none
    /// Codex 订阅额度快照 — 直接来自 Codex JSONL 里 OpenAI 后端缓存的 rate_limits（不发请求）。
    /// 没有 Codex 会话或所有 Codex 会话都没带 snapshot 时为 nil。
    @Published var codexRateLimits: CodexRateLimitsSnapshot?

    enum StatsTab: String, CaseIterable {
        case claudeCode = "Claude Code"
        case cursor = "Cursor"
    }

    /// Filter 阶段的计算结果（不含 projects，projects 在 loadData 中独立加载）
    struct FilterResult {
        let stats: SessionStats
        let recentSessions: [Session]
        let filteredSessions: [Session]
        let todayTokens: Int
        let todayCost: Double
        let todaySessions: Int
        let dailyStats: [DailyStatPoint]
        let weeklyCost: Double
    }

    private let burnMonitor = UsageBurnMonitor()
    private static let hugeDatasetFileThreshold = 3000
    private static let hugeDatasetRecentDays = 30
    private var refreshTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    /// 刷新代次：每次 refresh/setTimeFilter 递增，
    /// 只有最新代次的 Task 能重置 isLoading，避免旧 Task 竞态覆盖。
    private var refreshGeneration: UInt = 0

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
    /// Sessions currently contributing to `stats` (after time filter).
    private var currentFilteredSessions: [Session] = []
    /// 上次完整解析时各 JSONL 文件的修改时间快照。key = 文件绝对路径。
    private var cachedFileModTimes: [String: Date] = [:]
    private var cachedSkillStats: [String: SkillUsage] = [:]
    private var deferredHistoricalFilePaths: [String] = []
    private var lastRateLimitFetch: Date?
    private var conversationLoadTask: Task<Void, Never>?
    private var historicalLoadTask: Task<Void, Never>?

    // MARK: - Version Update
    @Published var updateAvailable: String?  // 新版本号（nil = 无更新）

    init() {
        // 初始加载数据（状态栏需要），但不启动定时刷新。
        // 定时刷新仅在面板可见时运行（通过 isPanelVisible didSet 控制）。
        isLoading = true
        let gen = refreshGeneration
        Task {
            defer { if gen == refreshGeneration { isLoading = false } }
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
        isLoading = true
        refreshGeneration &+= 1
        let gen = refreshGeneration
        refreshTask = Task {
            defer { if gen == refreshGeneration { isLoading = false } }
            await fullRefresh()
        }
    }

    func selectSource(_ source: DataSource) {
        selectedSource = source
        activeTab = (source == .cursor) ? .cursor : .claudeCode
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
        if filter == .all {
            triggerDeferredHistoricalLoadIfNeeded()
        }
        if !cachedSessions.isEmpty {
            refreshTask?.cancel()
            isLoading = true
            refreshGeneration &+= 1
            let gen = refreshGeneration
            refreshTask = Task {
                defer { if gen == refreshGeneration { isLoading = false } }
                await applyFilterAndUpdate()
            }
        } else {
            refresh()
        }
    }

    func toggleConversationPanel() {
        let willShow = !showConversationPanel
        showConversationPanel = willShow
        if willShow {
            prepareConversationSessions()
            loadConversationSessionsInBackground()
        } else {
            conversationLoadTask?.cancel()
            conversationLoadTask = nil
            isConversationLoading = false
            conversationSessions = []
        }
    }

    // MARK: - Core Refresh Pipeline

    /// 完整刷新 = 磁盘加载（重） + 内存筛选（轻）
    /// isLoading 由调用方设置为 true，applyFilterAndUpdate 通过 generation 检查清除。
    private func fullRefresh() async {
        await loadData()
        await applyFilterAndUpdate()
    }

    // MARK: - Phase 1: Load Data (disk I/O)

    /// 从磁盘解析 sessions 并缓存。
    /// - 缓存为空或 source/project 变更时：全量解析
    /// - 缓存存在且 source/project 未变：增量检查文件修改时间，只解析变化文件
    private func loadData() async {
        let currentSource = selectedSource
        let currentProject = selectedProject

        let needFullReparse = cachedSessions.isEmpty
            || cachedSource != currentSource
            || cachedProject != currentProject

        if needFullReparse {
            // 全量解析路径（支持渐进式首屏渲染）
            if currentProject == nil {
                let (loadedProjects, currentModTimes, changedFiles) = await Task.detached(priority: .userInitiated) {
                    Self.incrementalCheckForSource(currentSource, project: nil, oldModTimes: [:])
                }.value

                let sortedFiles = changedFiles.sorted {
                    (currentModTimes[$0] ?? .distantPast) > (currentModTimes[$1] ?? .distantPast)
                }

                cachedProjects = loadedProjects
                cachedSource = currentSource
                cachedProject = currentProject
                cachedFileModTimes = currentModTimes
                historicalLoadTask?.cancel()
                historicalLoadTask = nil

                guard !sortedFiles.isEmpty else {
                    cachedSessions = []
                    cachedSkillStats = [:]
                    deferredHistoricalFilePaths = []
                    return
                }

                var initialFiles = sortedFiles
                var deferredFiles: [String] = []
                if sortedFiles.count >= Self.hugeDatasetFileThreshold {
                    let cutoff = Calendar.current.date(
                        byAdding: .day,
                        value: -Self.hugeDatasetRecentDays,
                        to: Date()
                    ) ?? .distantPast
                    let recentFiles = sortedFiles.filter { (currentModTimes[$0] ?? .distantPast) >= cutoff }
                    let oldFiles = sortedFiles.filter { (currentModTimes[$0] ?? .distantPast) < cutoff }
                    if !recentFiles.isEmpty {
                        initialFiles = recentFiles
                        deferredFiles = oldFiles
                    }
                }

                let firstBatchSize = min(120, initialFiles.count)
                let firstBatch = Array(initialFiles.prefix(firstBatchSize))
                let remaining = Array(initialFiles.dropFirst(firstBatchSize))

                let firstSessions = await Task.detached(priority: .userInitiated) {
                    Self.parseSessions(forFiles: firstBatch, source: currentSource, compactForMemory: true)
                }.value

                cachedSessions = firstSessions
                cachedSkillStats = SessionAnalyzer.collectAllSkillStats(firstSessions)
                deferredHistoricalFilePaths = deferredFiles

                // 先渲染第一屏，避免等待全量文件解析完成
                if !remaining.isEmpty {
                    await applyFilterAndUpdate(lightweight: true)
                }

                if !remaining.isEmpty {
                    var allSessions = firstSessions
                    let chunkSize = 220
                    var idx = 0
                    while idx < remaining.count {
                        if Task.isCancelled { return }
                        let end = min(idx + chunkSize, remaining.count)
                        let chunk = Array(remaining[idx..<end])
                        let parsedChunk = await Task.detached(priority: .utility) {
                            Self.parseSessions(forFiles: chunk, source: currentSource, compactForMemory: true)
                        }.value
                        allSessions.append(contentsOf: parsedChunk)
                        idx = end
                    }
                    cachedSessions = allSessions
                    cachedSkillStats = SessionAnalyzer.collectAllSkillStats(allSessions)
                }
            } else {
                // 指定项目时按原路径解析，保证路径筛选语义准确
                let (loadedProjects, sessions, fileModTimes) = await Task.detached(priority: .userInitiated) {
                    Self.fullParseForSource(currentSource, project: currentProject)
                }.value

                let compacted = await Task.detached(priority: .utility) {
                    Self.compactSessionsForMemory(sessions)
                }.value

                cachedProjects = loadedProjects
                cachedSessions = compacted
                cachedSource = currentSource
                cachedProject = currentProject
                cachedFileModTimes = fileModTimes
                cachedSkillStats = SessionAnalyzer.collectAllSkillStats(compacted)
                deferredHistoricalFilePaths = []
                historicalLoadTask?.cancel()
                historicalLoadTask = nil
            }
            Self.releaseMemoryPressureIfPossible()
        } else {
            // 增量检查路径：source/project 未变，只检查文件是否有变化
            let oldModTimes = cachedFileModTimes

            let (loadedProjects, currentModTimes, changedFiles) = await Task.detached(priority: .userInitiated) {
                Self.incrementalCheckForSource(currentSource, project: currentProject, oldModTimes: oldModTimes)
            }.value

            // 更新 projects 列表（轻量操作，始终刷新）
            cachedProjects = loadedProjects

            // 如果没有任何文件变化，纯缓存命中，直接 return
            guard !changedFiles.isEmpty else { return }

            // 只解析变化的文件
            let newSessions = await Task.detached(priority: .userInitiated) {
                Self.parseSessions(forFiles: changedFiles, source: currentSource, compactForMemory: true)
            }.value

            // 将变化文件的路径收集为 Set，用于替换/追加
            let changedPaths = Set(changedFiles)

            // 移除旧的同路径 session，追加新解析的 session
            var updated = cachedSessions.filter { !changedPaths.contains($0.filePath) }
            updated.append(contentsOf: newSessions)
            cachedSessions = updated
            cachedFileModTimes = currentModTimes
            cachedSkillStats = SessionAnalyzer.collectAllSkillStats(updated)
            if !deferredHistoricalFilePaths.isEmpty {
                deferredHistoricalFilePaths.removeAll { changedPaths.contains($0) }
            }
            Self.releaseMemoryPressureIfPossible()
        }
    }

    // MARK: - Static Parse Helpers (called from Task.detached)

    /// 全量解析：返回 (projects, sessions, fileModTimes)
    nonisolated private static func fullParseForSource(
        _ source: DataSource,
        project: ProjectInfo?
    ) -> ([ProjectInfo], [Session], [String: Date]) {
        let claudeParser = SessionParser()
        let codexParser = CodexParser()
        let geminiParser = GeminiParser()
        let fm = FileManager.default

        var projects: [ProjectInfo] = []
        var sessions: [Session] = []

        switch source {
        case .all:
            projects = claudeParser.findAllProjects()
                + codexParser.findAllProjects()
                + geminiParser.findAllProjects()
            if let project = project {
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
            if let project = project {
                sessions = claudeParser.parseSessions(forProject: project.path)
            } else {
                sessions = claudeParser.parseAllSessions()
            }
        case .codex:
            projects = codexParser.findAllProjects()
            if let project = project {
                sessions = codexParser.parseSessions(forProject: project.path)
            } else {
                sessions = codexParser.parseAllSessions()
            }
        case .gemini:
            projects = geminiParser.findAllProjects()
            if let project = project {
                sessions = geminiParser.parseSessions(forProject: project.path)
            } else {
                sessions = geminiParser.parseAllSessions()
            }
        case .cursor:
            projects = claudeParser.findAllProjects()
            sessions = []
        }

        // 构建文件修改时间快照
        var modTimes: [String: Date] = [:]
        for session in sessions {
            let path = session.filePath
            if modTimes[path] == nil,
               let attrs = try? fm.attributesOfItem(atPath: path),
               let mtime = attrs[.modificationDate] as? Date {
                modTimes[path] = mtime
            }
        }

        return (projects, sessions, modTimes)
    }

    /// 增量检查：收集当前文件修改时间，与旧快照对比，返回变化文件列表。
    nonisolated private static func incrementalCheckForSource(
        _ source: DataSource,
        project: ProjectInfo?,
        oldModTimes: [String: Date]
    ) -> ([ProjectInfo], [String: Date], [String]) {
        let claudeParser = SessionParser()
        let codexParser = CodexParser()
        let geminiParser = GeminiParser()

        var projects: [ProjectInfo] = []
        var allFilePaths: [String] = []

        switch source {
        case .all:
            projects = claudeParser.findAllProjects()
                + codexParser.findAllProjects()
                + geminiParser.findAllProjects()
            if let project = project {
                // Claude 按 project 目录筛选；Codex/Gemini 按 project 后过滤，需收集全量文件
                allFilePaths = claudeParser.allSessionFilePaths(forProject: project.path)
                    + codexParser.allSessionFilePaths()
                    + geminiParser.allSessionFilePaths()
            } else {
                allFilePaths = claudeParser.allSessionFilePaths()
                    + codexParser.allSessionFilePaths()
                    + geminiParser.allSessionFilePaths()
            }
        case .claudeCode:
            projects = claudeParser.findAllProjects()
            if let project = project {
                allFilePaths = claudeParser.allSessionFilePaths(forProject: project.path)
            } else {
                allFilePaths = claudeParser.allSessionFilePaths()
            }
        case .codex:
            projects = codexParser.findAllProjects()
            allFilePaths = codexParser.allSessionFilePaths()
        case .gemini:
            projects = geminiParser.findAllProjects()
            allFilePaths = geminiParser.allSessionFilePaths()
        case .cursor:
            projects = claudeParser.findAllProjects()
            allFilePaths = []
        }

        // 收集当前文件修改时间
        let fm = FileManager.default
        var currentModTimes: [String: Date] = [:]
        for path in allFilePaths {
            if let attrs = try? fm.attributesOfItem(atPath: path),
               let mtime = attrs[.modificationDate] as? Date {
                currentModTimes[path] = mtime
            }
        }

        // 与旧快照对比，找出变化文件（新增 + 已修改）
        var changedFiles: [String] = []
        for (path, mtime) in currentModTimes {
            if let oldMtime = oldModTimes[path] {
                if mtime > oldMtime {
                    changedFiles.append(path)
                }
            } else {
                // 新文件
                changedFiles.append(path)
            }
        }

        return (projects, currentModTimes, changedFiles)
    }

    /// 仅解析指定文件路径列表中的 session。
    nonisolated private static func parseSessions(
        forFiles files: [String],
        source: DataSource,
        compactForMemory: Bool
    ) -> [Session] {
        _ = source
        let claudeParser = SessionParser()
        let codexParser = CodexParser()
        let geminiParser = GeminiParser()

        var parsed: [Session] = []
        parsed.reserveCapacity(files.count)

        for filePath in files {
            if Task.isCancelled { break }
            let session: Session? = autoreleasepool {
                if filePath.contains("/.claude/") {
                    return claudeParser.parseSessionFile(atPath: filePath)
                } else if filePath.contains("/.codex/") {
                    return codexParser.parseSessionFile(atPath: filePath)
                } else if filePath.contains("/.gemini/") {
                    return geminiParser.parseSessionFile(atPath: filePath)
                }
                return nil
            }
            guard let session else { continue }
            parsed.append(compactForMemory ? compactSession(session) : session)
        }
        return parsed
    }

    // MARK: - Memory Compaction

    /// 仅为最近会话保留完整消息内容，其余历史会话压缩为统计所需字段，降低常驻内存。
    nonisolated private static func compactSessionsForMemory(
        _ sessions: [Session],
        keepRecentCount: Int = 0
    ) -> [Session] {
        guard sessions.count > keepRecentCount else { return sessions }

        let keepPaths = Set(
            sessions
                .sorted { ($0.endTime ?? .distantPast) > ($1.endTime ?? .distantPast) }
                .prefix(keepRecentCount)
                .map(\.filePath)
        )

        return sessions.map { session in
            guard !keepPaths.contains(session.filePath) else { return session }
            return compactSession(session)
        }
    }

    /// 在一组 sessions 里挑出 codexRateLimitsTs 最新的一条 snapshot；都没有则返回 nil。
    nonisolated private static func latestCodexRateLimits(in sessions: [Session]) -> CodexRateLimitsSnapshot? {
        var bestSnap: CodexRateLimitsSnapshot?
        var bestTs: Date?
        for s in sessions {
            guard let snap = s.codexRateLimits, let ts = s.codexRateLimitsTs else { continue }
            if bestTs == nil || ts > bestTs! {
                bestTs = ts
                bestSnap = snap
            }
        }
        return bestSnap
    }

    nonisolated private static func compactSession(_ session: Session) -> Session {
        let compactedMessages = session.messages.map { message in
            let compactedCalls = message.toolCalls.map(compactToolCall)
            return Message(
                role: message.role,
                content: "",
                model: message.model,
                timestamp: message.timestamp,
                toolCalls: compactedCalls,
                toolResultInfos: message.toolResultInfos,
                tokenUsage: message.tokenUsage,
                isToolResult: message.isToolResult,
                isMeta: message.isMeta,
                messageId: message.messageId
            )
        }

        return Session(
            filePath: session.filePath,
            messages: compactedMessages,
            projectPath: session.projectPath,
            codexRateLimits: session.codexRateLimits,
            codexRateLimitsTs: session.codexRateLimitsTs
        )
    }

    nonisolated private static func compactToolCall(_ call: ToolCall) -> ToolCall {
        var input: [String: Any] = [:]

        if let filePath = call.input["file_path"] as? String { input["file_path"] = filePath }
        if let targetFile = call.input["target_file"] as? String { input["target_file"] = targetFile }
        if let skill = call.input["skill"] as? String { input["skill"] = skill }

        if let oldLines = call.input["__old_lines"] as? Int { input["__old_lines"] = oldLines }
        if let newLines = call.input["__new_lines"] as? Int { input["__new_lines"] = newLines }
        if let contentLines = call.input["__content_lines"] as? Int { input["__content_lines"] = contentLines }

        if call.name == "Write" {
            let content = call.input["content"] as? String ?? ""
            input["__content_lines"] = fastLineCount(content)
        } else if call.name == "Edit" {
            let oldString = call.input["old_string"] as? String ?? ""
            var newString = call.input["new_string"] as? String ?? ""
            if oldString.isEmpty && newString.isEmpty {
                newString = call.input["code_edit"] as? String ?? ""
            }
            input["__old_lines"] = fastLineCount(oldString)
            input["__new_lines"] = fastLineCount(newString)
        }

        // 仅保留少量可读字段，避免大字符串常驻内存
        if let cmd = call.input["cmd"] as? String, !cmd.isEmpty {
            input["cmd"] = String(cmd.prefix(200))
        }
        if let query = call.input["query"] as? String, !query.isEmpty {
            input["query"] = String(query.prefix(200))
        }
        if let q = call.input["q"] as? String, !q.isEmpty {
            input["q"] = String(q.prefix(200))
        }

        return ToolCall(
            name: call.name,
            timestamp: call.timestamp,
            inputLength: call.inputLength,
            input: input,
            toolUseId: call.toolUseId
        )
    }

    nonisolated private static func fastLineCount(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty else { return 0 }
        var count = 1
        for b in trimmed.utf8 where b == 10 { // '\n'
            count += 1
        }
        return count
    }

    /// Ask malloc to release unused pages after heavy parse/compaction work.
    nonisolated private static func releaseMemoryPressureIfPossible() {
        #if canImport(Darwin)
        if let zone = malloc_default_zone() {
            _ = malloc_zone_pressure_relief(zone, 1_000_000_000)
        }
        #endif
    }


    // MARK: - Phase 2: Apply Filter (in-memory)

    /// 基于缓存 sessions 做时间过滤、统计分析、日统计。无磁盘 I/O。
    private func applyFilterAndUpdate(lightweight: Bool = false) async {

        let sessions = cachedSessions
        let loadedProjects = cachedProjects
        let currentFilter = timeFilter
        let currentSource = selectedSource
        let skillStats = cachedSkillStats
        let previousDaily = dailyStats
        let previousTodayTokens = todayTokens
        let previousTodayCost = todayCost
        let previousTodaySessions = todaySessions

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

            var stats = SessionAnalyzer.analyze(
                sessions: filteredSessions,
                since: currentFilter.startDate
            )

            // Skill 统计始终基于全量 sessions（不受时间筛选），
            // 因为 Skill 使用模式在全时间维度更有意义。复用 loadData 阶段的缓存。
            stats.skillStats = skillStats

            // 会话列表按最近活跃时间排序（不受时间筛选影响）
            let recent = sessions
                .sorted { ($0.endTime ?? .distantPast) > ($1.endTime ?? .distantPast) }
                .prefix(30).map { $0 }

            let daily: [DailyStatPoint]
            let todayTokensValue: Int
            let todayCostValue: Double
            let todaySessionsValue: Int
            let weeklyCost: Double
            if lightweight {
                daily = previousDaily
                todayTokensValue = previousTodayTokens
                todayCostValue = previousTodayCost
                todaySessionsValue = previousTodaySessions
                weeklyCost = previousDaily.suffix(7).reduce(0.0) { $0 + $1.cost }
            } else {
                // 14 天日统计（单次分桶算法，today 是最后一个桶）
                daily = Self.computeDailyStats(from: sessions)
                let todayPoint = daily.last
                todayTokensValue = todayPoint?.tokens ?? 0
                todayCostValue = todayPoint?.cost ?? 0
                todaySessionsValue = todayPoint?.sessions ?? 0
                weeklyCost = daily.suffix(7).reduce(0.0) { $0 + $1.cost }
            }

            return FilterResult(
                stats: stats,
                recentSessions: recent,
                filteredSessions: filteredSessions,
                todayTokens: todayTokensValue,
                todayCost: todayCostValue,
                todaySessions: todaySessionsValue,
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

        if !lightweight {
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
        }

        self.currentFilteredSessions = result.filteredSessions
        self.lastRefreshed = Date()

        // 从 filteredSessions 里挑时间戳最新的 Codex snapshot 公布给 UI
        let newCodexRL = StatsViewModel.latestCodexRateLimits(in: result.filteredSessions)
        if self.codexRateLimits != newCodexRL {
            self.codexRateLimits = newCodexRL
        }

        if showConversationPanel {
            prepareConversationSessions()
            loadConversationSessionsInBackground()
        }

        if currentFilter == .all {
            triggerDeferredHistoricalLoadIfNeeded()
        }

        if !lightweight {
            // 懒加载 git stats（后台异步，不阻塞 UI）
            triggerGitStatsCollection(for: result.filteredSessions)

            // 获取用量额度（如果配置了 token），60 秒节流
            fetchRateLimitIfNeeded()

            // 检查用量预警
            checkAlerts(dailyCost: result.todayCost, weeklyCost: result.weeklyCost)
        }
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
            let dayEnd = calendar.date(byAdding: .day, value: i + 1, to: rangeStart)!
            // 传入 until 使跨日 session 的 token 只计入当天部分
            let dayStats = SessionAnalyzer.analyze(sessions: buckets[i], since: dayStart, until: dayEnd)

            return DailyStatPoint(
                date: dayStart,
                label: formatter.string(from: dayStart),
                sessions: buckets[i].count,
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

    private func triggerDeferredHistoricalLoadIfNeeded() {
        guard historicalLoadTask == nil else { return }
        guard !deferredHistoricalFilePaths.isEmpty else { return }

        let deferredPaths = deferredHistoricalFilePaths
        deferredHistoricalFilePaths = []
        let sourceAtStart = selectedSource
        let projectAtStart = selectedProject

        historicalLoadTask = Task { [deferredPaths] in
            defer { self.historicalLoadTask = nil }

            var parsedAll: [Session] = []
            parsedAll.reserveCapacity(deferredPaths.count)
            let chunkSize = 260
            var idx = 0

            while idx < deferredPaths.count {
                if Task.isCancelled { return }
                let end = min(idx + chunkSize, deferredPaths.count)
                let chunk = Array(deferredPaths[idx..<end])
                let parsedChunk = await Task.detached(priority: .utility) {
                    Self.parseSessions(forFiles: chunk, source: sourceAtStart, compactForMemory: true)
                }.value
                if Task.isCancelled { return }
                parsedAll.append(contentsOf: parsedChunk)
                idx = end
            }

            guard !Task.isCancelled else { return }
            guard self.selectedSource == sourceAtStart, self.selectedProject == projectAtStart else { return }
            guard !parsedAll.isEmpty else { return }

            let existingPaths = Set(self.cachedSessions.map(\.filePath))
            let appended = parsedAll.filter { !existingPaths.contains($0.filePath) }
            guard !appended.isEmpty else { return }

            self.cachedSessions.append(contentsOf: appended)
            self.cachedSkillStats = SessionAnalyzer.collectAllSkillStats(self.cachedSessions)
            Self.releaseMemoryPressureIfPossible()
            await self.applyFilterAndUpdate()
        }
    }

    // MARK: - Conversation Lazy Loading

    private func prepareConversationSessions() {
        let base = currentFilteredSessions.isEmpty ? recentSessions : currentFilteredSessions
        let ordered = base
            .sorted { ($0.endTime ?? .distantPast) > ($1.endTime ?? .distantPast) }
            .prefix(30)
            .map { $0 }
        if conversationSessions != ordered {
            conversationSessions = ordered
        }
    }

    private func loadConversationSessionsInBackground() {
        guard showConversationPanel else { return }
        let targetPaths = conversationSessions.map(\.filePath)
        guard !targetPaths.isEmpty else { return }

        conversationLoadTask?.cancel()
        isConversationLoading = true

        let source = selectedSource
        conversationLoadTask = Task { [targetPaths] in
            let fullSessions = await Task.detached(priority: .utility) {
                Self.parseSessions(forFiles: targetPaths, source: source, compactForMemory: false)
            }.value

            guard !Task.isCancelled else { return }
            let fullByPath = Dictionary(uniqueKeysWithValues: fullSessions.map { ($0.filePath, $0) })
            let ordered = targetPaths.compactMap { fullByPath[$0] }
            if self.showConversationPanel {
                self.conversationSessions = ordered
            }
            self.isConversationLoading = false
        }
    }

    private func invalidateCache() {
        cachedSessions = []
        cachedProjects = []
        cachedSource = nil
        cachedProject = nil
        cachedFileModTimes = [:]
        cachedSkillStats = [:]
        deferredHistoricalFilePaths = []
        conversationLoadTask?.cancel()
        conversationLoadTask = nil
        historicalLoadTask?.cancel()
        historicalLoadTask = nil
        conversationSessions = []
        isConversationLoading = false
        GitStatsCollector.shared.clearCache()
    }

    // MARK: - Git Stats Lazy Loading

    /// Trigger background git stats collection for sessions with a project path.
    /// When each session's git stats arrive, merge them into the published `stats`.
    private func triggerGitStatsCollection(for sessions: [Session]) {
        let sessionsWithProject = sessions.filter { $0.projectPath != nil }
        guard !sessionsWithProject.isEmpty else { return }

        for session in sessionsWithProject {
            GitStatsCollector.shared.collect(for: session) { [weak self] _, result in
                guard let self, result != .zero else { return }
                self.mergeGitStats()
            }
        }
    }

    /// Re-merge git stats from cache into the current stats snapshot.
    private func mergeGitStats() {
        guard let current = self.stats else { return }
        var commits = 0
        var additions = 0
        var deletions = 0

        for session in currentFilteredSessions {
            if let cached = GitStatsCollector.shared.cached(for: session) {
                commits += cached.commits
                additions += cached.additions
                deletions += cached.deletions
            }
        }

        let updated = SessionStats(
            userInstructions: current.userInstructions,
            toolCalls: current.toolCalls,
            totalDuration: current.totalDuration,
            aiProcessingTime: current.aiProcessingTime,
            userActiveTime: current.userActiveTime,
            codeChanges: current.codeChanges,
            tokenUsage: current.tokenUsage,
            sessionCount: current.sessionCount,
            gitCommits: commits,
            gitAdditions: additions,
            gitDeletions: deletions,
            skillStats: current.skillStats
        )

        if self.stats != updated {
            self.stats = updated
        }
    }

    private func fetchRateLimitIfNeeded() {
        let now = Date()
        if let last = lastRateLimitFetch, now.timeIntervalSince(last) < 60 { return }
        lastRateLimitFetch = now
        fetchRateLimit()
    }

    private func fetchRateLimit() {
        UsageAPI.fetch { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let data):
                    self.rateLimitData = data
                    self.isTokenExpired = false
                    self.burnMonitor.process(data: data)
                    let new5h = self.burnMonitor.alertLevel5h
                    let new7d = self.burnMonitor.alertLevel7d
                    if self.burnAlertLevel5h != new5h { self.burnAlertLevel5h = new5h }
                    if self.burnAlertLevel7d != new7d { self.burnAlertLevel7d = new7d }
                case .tokenExpired:
                    self.rateLimitData = nil
                    self.isTokenExpired = true
                case .networkError:
                    break  // keep stale data, don't change expired state
                case .noToken:
                    self.rateLimitData = nil
                    self.isTokenExpired = false
                }
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

                // 仅在首次发现新版本时触发自动升级
                if self.hasNotifiedVersion != latestVersion {
                    self.hasNotifiedVersion = latestVersion
                    self.autoUpgrade(to: latestVersion)
                }
            }
        }
    }

    /// 后台自动升级 cc-statistics 到指定版本
    private func autoUpgrade(to version: String) {
        sendSystemNotification(
            title: "cc-statistics 自动升级",
            body: "正在自动升级到 v\(version)..."
        )

        Task.detached(priority: .utility) {
            let (exitCode, stderr) = Self.runUpgradeProcess()

            await MainActor.run { [weak self] in
                guard let self else { return }
                if exitCode == 0 {
                    self.sendSystemNotification(
                        title: "cc-statistics 升级完成",
                        body: "已升级到 v\(version)，请重启 CCStats"
                    )
                } else {
                    let errorMsg = stderr.isEmpty ? "未知错误" : stderr
                    self.sendSystemNotification(
                        title: "cc-statistics 升级失败",
                        body: "升级失败：\(errorMsg)"
                    )
                }
            }
        }
    }

    /// 执行升级命令，返回 (exitCode, stderr)
    nonisolated private static func runUpgradeProcess() -> (Int32, String) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        // 按优先级搜索 pipx
        let pipxPaths = [
            "\(home)/.local/bin/pipx",
            "/opt/homebrew/bin/pipx",
            "/usr/local/bin/pipx",
            "/usr/bin/pipx",
        ]

        let process = Process()
        process.environment = ProcessInfo.processInfo.environment

        if let pipxPath = pipxPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            process.executableURL = URL(fileURLWithPath: pipxPath)
            process.arguments = ["upgrade", "cc-statistics"]
        } else {
            // fallback 到 pip
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["pip", "install", "--upgrade", "cc-statistics"]
        }

        let stderrPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (1, error.localizedDescription)
        }

        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrStr = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return (process.terminationStatus, stderrStr)
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
