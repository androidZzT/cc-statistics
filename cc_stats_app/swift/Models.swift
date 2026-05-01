import Foundation

// MARK: - Data Source

enum DataSource: String, CaseIterable, Identifiable {
    case all
    case claudeCode
    case codex
    case gemini
    case cursor

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return L10n.allSources
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .gemini: return "Gemini CLI"
        case .cursor: return "Cursor"
        }
    }

    var icon: String {
        switch self {
        case .all: return "square.stack.3d.up"
        case .claudeCode: return "sparkles"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .gemini: return "diamond"
        case .cursor: return "cursorarrow.rays"
        }
    }
}

// MARK: - Token Detail

struct TokenDetail: Codable, Equatable {
    var inputTokens: Int
    var outputTokens: Int
    var cacheCreationInputTokens: Int
    var cacheReadInputTokens: Int

    init(
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheCreationInputTokens: Int = 0,
        cacheReadInputTokens: Int = 0
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
    }

    var totalTokens: Int {
        inputTokens + outputTokens + cacheCreationInputTokens + cacheReadInputTokens
    }

    static func + (lhs: TokenDetail, rhs: TokenDetail) -> TokenDetail {
        TokenDetail(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cacheCreationInputTokens: lhs.cacheCreationInputTokens + rhs.cacheCreationInputTokens,
            cacheReadInputTokens: lhs.cacheReadInputTokens + rhs.cacheReadInputTokens
        )
    }

    static func += (lhs: inout TokenDetail, rhs: TokenDetail) {
        lhs = lhs + rhs
    }
}

// MARK: - Tool Call

struct ToolCall: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let timestamp: Date?
    let inputLength: Int
    let input: [String: Any]
    let toolUseId: String?

    init(name: String, timestamp: Date? = nil, inputLength: Int = 0, input: [String: Any] = [:], toolUseId: String? = nil) {
        self.name = name
        self.timestamp = timestamp
        self.inputLength = inputLength
        self.input = input
        self.toolUseId = toolUseId
    }

    static func == (lhs: ToolCall, rhs: ToolCall) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Tool Result Info

struct ToolResultInfo: Equatable {
    let toolUseId: String
    let isError: Bool
}

// MARK: - Message

struct Message: Identifiable, Equatable {
    let id = UUID()
    let role: String
    let content: String
    let model: String?
    let timestamp: Date?
    let toolCalls: [ToolCall]
    let toolResultInfos: [ToolResultInfo]
    let tokenUsage: TokenDetail?
    let isToolResult: Bool
    let isMeta: Bool
    let messageId: String?  // API message ID，用于流式去重

    init(
        role: String,
        content: String = "",
        model: String? = nil,
        timestamp: Date? = nil,
        toolCalls: [ToolCall] = [],
        toolResultInfos: [ToolResultInfo] = [],
        tokenUsage: TokenDetail? = nil,
        isToolResult: Bool = false,
        isMeta: Bool = false,
        messageId: String? = nil
    ) {
        self.role = role
        self.content = content
        self.model = model
        self.timestamp = timestamp
        self.toolCalls = toolCalls
        self.toolResultInfos = toolResultInfos
        self.tokenUsage = tokenUsage
        self.isToolResult = isToolResult
        self.isMeta = isMeta
        self.messageId = messageId
    }

    static func == (lhs: Message, rhs: Message) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Session

// MARK: - Codex Rate-Limit Snapshot
//
// 镜像 OpenAI Codex 上游 protocol 中的 RateLimitSnapshot / RateLimitWindow，
// 由 CodexParser 直接从 event_msg/token_count.rate_limits 解析得到，
// 不发起任何网络请求 — 数据已被 Codex CLI 缓存到本地 JSONL。

struct CodexRateLimitWindow: Equatable {
    /// 0-100，OpenAI 后端给出的真实订阅消耗百分比
    let usedPercent: Double
    /// 滚动窗口长度（分钟）。primary 通常 ~300，secondary 通常 ~10080
    let windowMinutes: Int?
    /// 窗口重置的绝对时刻（OpenAI 给的是 Unix 秒，这里转成 Date）
    let resetsAt: Date?
}

struct CodexRateLimitsSnapshot: Equatable {
    /// 5 小时滚动窗口
    let primary: CodexRateLimitWindow?
    /// 周窗口
    let secondary: CodexRateLimitWindow?
}

struct Session: Identifiable, Equatable {
    let id = UUID()
    let filePath: String
    let messages: [Message]
    let projectPath: String?
    /// Codex JSONL 里 OpenAI 后端写下的订阅额度快照（来自 event_msg/token_count.rate_limits）。
    /// 仅 Codex 会话填充；其它来源恒为 nil。
    let codexRateLimits: CodexRateLimitsSnapshot?
    /// 上述 snapshot 对应的事件时间戳（用于跨会话挑最新一条）。
    let codexRateLimitsTs: Date?

    init(
        filePath: String,
        messages: [Message],
        projectPath: String?,
        codexRateLimits: CodexRateLimitsSnapshot? = nil,
        codexRateLimitsTs: Date? = nil
    ) {
        self.filePath = filePath
        self.messages = messages
        self.projectPath = projectPath
        self.codexRateLimits = codexRateLimits
        self.codexRateLimitsTs = codexRateLimitsTs
    }

    static func == (lhs: Session, rhs: Session) -> Bool {
        lhs.filePath == rhs.filePath && lhs.messages.count == rhs.messages.count
    }

    var sessionName: String {
        ((filePath as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    var startTime: Date? {
        messages.compactMap(\.timestamp).min()
    }

    var endTime: Date? {
        messages.compactMap(\.timestamp).max()
    }

    /// 峰值上下文使用量（input + cache_read + cache_creation 的最大值）
    var peakContextTokens: Int {
        messages.compactMap { msg -> Int? in
            guard let usage = msg.tokenUsage else { return nil }
            return usage.inputTokens + usage.cacheReadInputTokens + usage.cacheCreationInputTokens
        }.max() ?? 0
    }

    /// 上下文使用率（峰值 / 模型窗口大小）
    var contextUsagePercent: Double {
        let peak = peakContextTokens
        guard peak > 0 else { return 0 }
        let windowSize = contextWindowSize
        return Double(peak) / Double(windowSize) * 100
    }

    /// 根据模型名推断上下文窗口大小
    private var contextWindowSize: Int {
        let model = messages.compactMap(\.model).first ?? ""
        let lower = model.lowercased()
        if lower.contains("opus") { return 200_000 }
        if lower.contains("sonnet") { return 200_000 }
        if lower.contains("haiku") { return 200_000 }
        if lower.contains("gemini") { return 1_000_000 }
        if lower.contains("gpt-4o") { return 128_000 }
        if lower.contains("o1") || lower.contains("o3") { return 200_000 }
        return 200_000  // default
    }

    var duration: TimeInterval {
        guard let start = startTime, let end = endTime else { return 0 }
        return max(0, end.timeIntervalSince(start))
    }
}

// MARK: - Skill Usage

struct SkillUsage: Equatable {
    let name: String
    var callCount: Int = 0
    var successCount: Int = 0
    var errorCount: Int = 0
    var unknownCount: Int = 0

    var successRate: Int? {
        let resolved = successCount + errorCount
        guard resolved > 0 else { return nil }
        return Int(round(Double(successCount) / Double(resolved) * 100))
    }
}

// MARK: - Code Change

struct CodeChange: Identifiable, Equatable {
    let id = UUID()
    let filePath: String
    let language: String
    let additions: Int
    let deletions: Int

    static func == (lhs: CodeChange, rhs: CodeChange) -> Bool {
        lhs.filePath == rhs.filePath
            && lhs.language == rhs.language
            && lhs.additions == rhs.additions
            && lhs.deletions == rhs.deletions
    }
}

// MARK: - Session Stats

struct SessionStats: Equatable {
    var userInstructions: Int
    var toolCalls: [String: Int]
    var totalDuration: TimeInterval
    var aiProcessingTime: TimeInterval
    var userActiveTime: TimeInterval
    var codeChanges: [CodeChange]
    var tokenUsage: [String: TokenDetail]
    var sessionCount: Int
    var gitCommits: Int
    var gitAdditions: Int
    var gitDeletions: Int
    var skillStats: [String: SkillUsage]

    init(
        userInstructions: Int = 0,
        toolCalls: [String: Int] = [:],
        totalDuration: TimeInterval = 0,
        aiProcessingTime: TimeInterval = 0,
        userActiveTime: TimeInterval = 0,
        codeChanges: [CodeChange] = [],
        tokenUsage: [String: TokenDetail] = [:],
        sessionCount: Int = 0,
        gitCommits: Int = 0,
        gitAdditions: Int = 0,
        gitDeletions: Int = 0,
        skillStats: [String: SkillUsage] = [:]
    ) {
        self.userInstructions = userInstructions
        self.toolCalls = toolCalls
        self.totalDuration = totalDuration
        self.aiProcessingTime = aiProcessingTime
        self.userActiveTime = userActiveTime
        self.codeChanges = codeChanges
        self.tokenUsage = tokenUsage
        self.sessionCount = sessionCount
        self.gitCommits = gitCommits
        self.gitAdditions = gitAdditions
        self.gitDeletions = gitDeletions
        self.skillStats = skillStats
    }

    var totalInputTokens: Int {
        tokenUsage.values.reduce(0) { $0 + $1.inputTokens }
    }

    var totalOutputTokens: Int {
        tokenUsage.values.reduce(0) { $0 + $1.outputTokens }
    }

    var totalCacheCreationTokens: Int {
        tokenUsage.values.reduce(0) { $0 + $1.cacheCreationInputTokens }
    }

    var totalCacheReadTokens: Int {
        tokenUsage.values.reduce(0) { $0 + $1.cacheReadInputTokens }
    }

    var totalTokens: Int {
        tokenUsage.values.reduce(0) { $0 + $1.totalTokens }
    }

    var estimatedCost: Double {
        CostEstimator.estimateCost(tokenUsage: tokenUsage)
    }

    // MARK: - Efficiency Score

    var totalCodeLines: Int {
        var total = 0
        for c in codeChanges { total += c.additions + c.deletions }
        return total
    }

    var codePerKToken: Double {
        let total = Double(totalTokens)
        guard total > 0 else { return 0 }
        return Double(totalCodeLines) / (total / 1000.0)
    }

    var avgTokensPerInstruction: Int {
        guard userInstructions > 0 else { return 0 }
        return totalTokens / userInstructions
    }

    var aiUtilizationRate: Double {
        let activeTime = aiProcessingTime + userActiveTime
        guard activeTime > 0 else { return 0 }
        return aiProcessingTime / activeTime * 100
    }

    var efficiencyCodeScore: Int {
        min(40, Int(codePerKToken / 0.5 * 40))
    }

    var efficiencyPrecisionScore: Int {
        max(0, min(30, Int((1 - Double(min(avgTokensPerInstruction, 200_000)) / 200_000) * 30)))
    }

    var efficiencyUtilScore: Int {
        min(30, Int(aiUtilizationRate / 70 * 30))
    }

    var efficiencyTotalScore: Int {
        efficiencyCodeScore + efficiencyPrecisionScore + efficiencyUtilScore
    }

    var efficiencyGrade: String {
        let s = efficiencyTotalScore
        if s >= 90 { return "S" }
        if s >= 75 { return "A" }
        if s >= 60 { return "B" }
        if s >= 40 { return "C" }
        return "D"
    }
}

// MARK: - Process Info

struct ProcessInfo2: Identifiable {
    let id = UUID()
    let pid: Int32
    let memoryMB: Double
    let command: String

    var displayName: String {
        if command.contains("CCStats") { return "CC Stats Panel" }
        if command.contains("cc-stats-web") { return "CC Stats Web" }
        if command.contains("--resume") {
            let parts = command.components(separatedBy: "--resume ")
            if parts.count > 1 {
                let sessionId = parts[1].trimmingCharacters(in: .whitespaces)
                return "Session: \(sessionId.prefix(20))..."
            }
        }
        if command.contains("--agent-id") { return "Agent Sub-process" }
        if command.contains("claude init") { return "Claude Init" }
        if command.contains("claude") { return "Claude Code" }
        return command.components(separatedBy: "/").last ?? command
    }

    static func scan() -> [ProcessInfo2] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["aux"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.qualityOfService = .background
        do { try process.run() } catch { return [] }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        var results: [ProcessInfo2] = []
        for line in output.components(separatedBy: "\n") {
            let lower = line.lowercased()
            guard lower.contains("claude") || lower.contains("ccstats") || lower.contains("cc-stats") || lower.contains("cc_stats") else { continue }
            guard !line.contains("grep") else { continue }

            let parts = line.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: true)
            guard parts.count >= 11 else { continue }

            guard let pid = Int32(parts[1]) else { continue }
            let memKB = Double(parts[5]) ?? 0
            let command = parts[10...].joined(separator: " ")

            results.append(ProcessInfo2(
                pid: pid,
                memoryMB: memKB / 1024,
                command: command
            ))
        }
        return results.sorted { $0.memoryMB > $1.memoryMB }
    }

    static func kill(pid: Int32) {
        Foundation.kill(pid, SIGTERM)
    }
}

// MARK: - Daily Stat Point

struct DailyStatPoint: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let label: String  // "03/18"
    let sessions: Int
    let messages: Int
    let tokens: Int
    let cost: Double
    let activeMinutes: Double

    static func == (lhs: DailyStatPoint, rhs: DailyStatPoint) -> Bool {
        lhs.label == rhs.label && lhs.tokens == rhs.tokens
            && lhs.cost == rhs.cost && lhs.sessions == rhs.sessions
    }
}

// MARK: - Cost Estimation

struct ModelPricing {
    let inputPerMillion: Double       // $/M input tokens
    let outputPerMillion: Double      // $/M output tokens
    let cacheReadPerMillion: Double   // $/M cache read tokens
    let cacheCreatePerMillion: Double // $/M cache creation tokens
}

enum CostEstimator {
    private static let pricing: [String: ModelPricing] = [
        // Claude
        "claude-opus-4.6": ModelPricing(inputPerMillion: 5.0, outputPerMillion: 25.0, cacheReadPerMillion: 0.5, cacheCreatePerMillion: 6.25),
        "claude-opus-4.5": ModelPricing(inputPerMillion: 5.0, outputPerMillion: 25.0, cacheReadPerMillion: 0.5, cacheCreatePerMillion: 6.25),
        "claude-opus-4.1": ModelPricing(inputPerMillion: 15.0, outputPerMillion: 75.0, cacheReadPerMillion: 1.5, cacheCreatePerMillion: 18.75),
        "claude-sonnet-4.6": ModelPricing(inputPerMillion: 3.0, outputPerMillion: 15.0, cacheReadPerMillion: 0.3, cacheCreatePerMillion: 3.75),
        "claude-sonnet-4.5": ModelPricing(inputPerMillion: 3.0, outputPerMillion: 15.0, cacheReadPerMillion: 0.3, cacheCreatePerMillion: 3.75),
        "claude-sonnet-4": ModelPricing(inputPerMillion: 3.0, outputPerMillion: 15.0, cacheReadPerMillion: 0.3, cacheCreatePerMillion: 3.75),
        "claude-haiku-4.5": ModelPricing(inputPerMillion: 1.0, outputPerMillion: 5.0, cacheReadPerMillion: 0.1, cacheCreatePerMillion: 1.25),
        "claude-haiku-legacy": ModelPricing(inputPerMillion: 0.8, outputPerMillion: 4.0, cacheReadPerMillion: 0.08, cacheCreatePerMillion: 1.0),
        // OpenAI / Codex
        "gpt-5.4": ModelPricing(inputPerMillion: 2.50, outputPerMillion: 15.00, cacheReadPerMillion: 0.25, cacheCreatePerMillion: 2.50),
        "gpt-5.4-mini": ModelPricing(inputPerMillion: 0.75, outputPerMillion: 4.50, cacheReadPerMillion: 0.075, cacheCreatePerMillion: 0.75),
        "gpt-5.4-nano": ModelPricing(inputPerMillion: 0.20, outputPerMillion: 1.25, cacheReadPerMillion: 0.020, cacheCreatePerMillion: 0.20),
        "gpt-5.3-codex": ModelPricing(inputPerMillion: 1.75, outputPerMillion: 14.00, cacheReadPerMillion: 0.175, cacheCreatePerMillion: 1.75),
        "gpt-5.3-chat-latest": ModelPricing(inputPerMillion: 1.75, outputPerMillion: 14.00, cacheReadPerMillion: 0.175, cacheCreatePerMillion: 1.75),
        "gpt-4o": ModelPricing(inputPerMillion: 2.50, outputPerMillion: 10.00, cacheReadPerMillion: 1.25, cacheCreatePerMillion: 2.50),
        "gpt-4o-mini": ModelPricing(inputPerMillion: 0.15, outputPerMillion: 0.60, cacheReadPerMillion: 0.075, cacheCreatePerMillion: 0.15),
        "o1": ModelPricing(inputPerMillion: 15.00, outputPerMillion: 60.00, cacheReadPerMillion: 7.5, cacheCreatePerMillion: 15.0),
        "o3": ModelPricing(inputPerMillion: 10.00, outputPerMillion: 40.00, cacheReadPerMillion: 2.5, cacheCreatePerMillion: 10.0),
        "o3-mini": ModelPricing(inputPerMillion: 1.10, outputPerMillion: 4.40, cacheReadPerMillion: 0.55, cacheCreatePerMillion: 1.10),
        "o4-mini": ModelPricing(inputPerMillion: 1.10, outputPerMillion: 4.40, cacheReadPerMillion: 0.55, cacheCreatePerMillion: 1.10),
        // Gemini
        "gemini-2.5-pro": ModelPricing(inputPerMillion: 1.25, outputPerMillion: 10.00, cacheReadPerMillion: 0.125, cacheCreatePerMillion: 1.25),
        "gemini-2.5-flash": ModelPricing(inputPerMillion: 0.30, outputPerMillion: 2.50, cacheReadPerMillion: 0.03, cacheCreatePerMillion: 0.30),
        "gemini-2.5-flash-lite": ModelPricing(inputPerMillion: 0.10, outputPerMillion: 0.40, cacheReadPerMillion: 0.01, cacheCreatePerMillion: 0.10),
        "gemini-2.0-flash": ModelPricing(inputPerMillion: 0.10, outputPerMillion: 0.40, cacheReadPerMillion: 0.025, cacheCreatePerMillion: 0.10),
    ]

    static func estimateCost(tokenUsage: [String: TokenDetail]) -> Double {
        var total = 0.0
        for (model, detail) in tokenUsage {
            let p = matchPricing(model)
            total += Double(detail.inputTokens) / 1_000_000 * p.inputPerMillion
            total += Double(detail.outputTokens) / 1_000_000 * p.outputPerMillion
            total += Double(detail.cacheReadInputTokens) / 1_000_000 * p.cacheReadPerMillion
            total += Double(detail.cacheCreationInputTokens) / 1_000_000 * p.cacheCreatePerMillion
        }
        return total
    }

    static func estimateCostForModel(_ model: String, detail: TokenDetail) -> Double {
        let p = matchPricing(model)
        var cost = 0.0
        cost += Double(detail.inputTokens) / 1_000_000 * p.inputPerMillion
        cost += Double(detail.outputTokens) / 1_000_000 * p.outputPerMillion
        cost += Double(detail.cacheReadInputTokens) / 1_000_000 * p.cacheReadPerMillion
        cost += Double(detail.cacheCreationInputTokens) / 1_000_000 * p.cacheCreatePerMillion
        return cost
    }

    private static func matchPricing(_ model: String) -> ModelPricing {
        let lower = model.lowercased()
        // OpenAI / Codex
        if lower.contains("gpt-5.4-mini") { return pricing["gpt-5.4-mini"]! }
        if lower.contains("gpt-5.4-nano") { return pricing["gpt-5.4-nano"]! }
        if lower.contains("gpt-5.4") { return pricing["gpt-5.4"]! }
        if lower.contains("gpt-5.3-chat-latest") { return pricing["gpt-5.3-chat-latest"]! }
        if lower.contains("gpt-5.3-codex") { return pricing["gpt-5.3-codex"]! }
        if lower.contains("gpt-5") && lower.contains("codex") { return pricing["gpt-5.3-codex"]! }
        if lower.contains("gpt-4o-mini") { return pricing["gpt-4o-mini"]! }
        if lower.contains("gpt-4o") { return pricing["gpt-4o"]! }
        if lower.contains("o4-mini") { return pricing["o4-mini"]! }
        if lower.contains("o3-mini") { return pricing["o3-mini"]! }
        if lower.contains("o3") { return pricing["o3"]! }
        if lower.contains("o1") { return pricing["o1"]! }

        // Gemini
        if lower.contains("gemini-2.5-pro") { return pricing["gemini-2.5-pro"]! }
        if lower.contains("gemini-2.5-flash-lite") { return pricing["gemini-2.5-flash-lite"]! }
        if lower.contains("gemini-2.5-flash") { return pricing["gemini-2.5-flash"]! }
        if lower.contains("gemini-2.0-flash") { return pricing["gemini-2.0-flash"]! }
        if lower.contains("gemini") { return pricing["gemini-2.5-flash"]! }

        // Claude
        if lower.contains("opus") {
            if lower.contains("4.6") || lower.contains("4-6") {
                return pricing["claude-opus-4.6"]!
            }
            if lower.contains("4.5") || lower.contains("4-5") {
                return pricing["claude-opus-4.5"]!
            }
            return pricing["claude-opus-4.1"]!
        }
        if lower.contains("haiku") {
            if lower.contains("4.5") || lower.contains("4-5") {
                return pricing["claude-haiku-4.5"]!
            }
            return pricing["claude-haiku-legacy"]!
        }
        if lower.contains("sonnet") {
            if lower.contains("4.6") || lower.contains("4-6") {
                return pricing["claude-sonnet-4.6"]!
            }
            if lower.contains("4.5") || lower.contains("4-5") {
                return pricing["claude-sonnet-4.5"]!
            }
            return pricing["claude-sonnet-4"]!
        }

        // Vendor fallback for unknown model strings
        if lower.contains("gpt") || lower.hasPrefix("o1") || lower.hasPrefix("o3") || lower.hasPrefix("o4") {
            return pricing["gpt-5.3-codex"]!
        }
        if lower.contains("gemini") { return pricing["gemini-2.5-flash"]! }
        return pricing["claude-sonnet-4.6"]!
    }

    static func formatCost(_ cost: Double) -> String {
        if cost >= 100 {
            return String(format: "$%.0f", cost)
        } else if cost >= 1 {
            return String(format: "$%.2f", cost)
        } else if cost >= 0.01 {
            return String(format: "$%.3f", cost)
        } else {
            return String(format: "$%.4f", cost)
        }
    }
}

// MARK: - Project Info

struct ProjectInfo: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let path: String
    let sessionCount: Int
    let lastActive: Date?

    func hash(into hasher: inout Hasher) {
        hasher.combine(path)
    }

    static func == (lhs: ProjectInfo, rhs: ProjectInfo) -> Bool {
        lhs.path == rhs.path
    }
}

// MARK: - Dashboard Module Settings

enum DashboardModule: String, CaseIterable, Identifiable {
    case rateLimit
    case developmentTime
    case codeChanges
    case toolCalls
    case skillStats
    case efficiency
    case costPrediction
    case processMonitor

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .rateLimit: return "gauge.with.dots.needle.50percent"
        case .developmentTime: return "chart.pie.fill"
        case .codeChanges: return "chevron.left.forwardslash.chevron.right"
        case .toolCalls: return "hammer.fill"
        case .skillStats: return "command.circle.fill"
        case .efficiency: return "gauge.with.dots.needle.33percent"
        case .costPrediction: return "chart.line.uptrend.xyaxis"
        case .processMonitor: return "memorychip"
        }
    }

    var labelChinese: String {
        switch self {
        case .rateLimit: return "用量额度"
        case .developmentTime: return "开发时间分析"
        case .codeChanges: return "代码变更"
        case .toolCalls: return "工具调用排行"
        case .skillStats: return "Skill 使用"
        case .efficiency: return "效率评分"
        case .costPrediction: return "费用预测"
        case .processMonitor: return "进程监控"
        }
    }

    var labelEnglish: String {
        switch self {
        case .rateLimit: return "Usage Quota"
        case .developmentTime: return "Development Time"
        case .codeChanges: return "Code Changes"
        case .toolCalls: return "Tool Calls"
        case .skillStats: return "Skill Usage"
        case .efficiency: return "Efficiency"
        case .costPrediction: return "Cost Prediction"
        case .processMonitor: return "Process Monitor"
        }
    }

    var label: String {
        L10n.isChinese ? labelChinese : labelEnglish
    }

    /// Default visibility — core modules are on by default
    var defaultVisible: Bool {
        switch self {
        case .costPrediction: return true
        default: return false
        }
    }

    // MARK: - UserDefaults persistence

    private var defaultsKey: String {
        "cc_stats_module_\(rawValue)"
    }

    var isVisible: Bool {
        get {
            let key = defaultsKey
            if UserDefaults.standard.object(forKey: key) == nil {
                return defaultVisible
            }
            return UserDefaults.standard.bool(forKey: key)
        }
        nonmutating set {
            UserDefaults.standard.set(newValue, forKey: defaultsKey)
        }
    }
}
