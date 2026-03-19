import Foundation

// MARK: - Data Source

enum DataSource: String, CaseIterable, Identifiable {
    case all
    case claudeCode
    case codex
    case cursor

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return L10n.allSources
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        }
    }

    var icon: String {
        switch self {
        case .all: return "square.stack.3d.up"
        case .claudeCode: return "sparkles"
        case .codex: return "chevron.left.forwardslash.chevron.right"
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

    init(name: String, timestamp: Date? = nil, inputLength: Int = 0, input: [String: Any] = [:]) {
        self.name = name
        self.timestamp = timestamp
        self.inputLength = inputLength
        self.input = input
    }

    static func == (lhs: ToolCall, rhs: ToolCall) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Message

struct Message: Identifiable, Equatable {
    let id = UUID()
    let role: String
    let content: String
    let model: String?
    let timestamp: Date?
    let toolCalls: [ToolCall]
    let tokenUsage: TokenDetail?

    init(
        role: String,
        content: String = "",
        model: String? = nil,
        timestamp: Date? = nil,
        toolCalls: [ToolCall] = [],
        tokenUsage: TokenDetail? = nil
    ) {
        self.role = role
        self.content = content
        self.model = model
        self.timestamp = timestamp
        self.toolCalls = toolCalls
        self.tokenUsage = tokenUsage
    }

    static func == (lhs: Message, rhs: Message) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Session

struct Session: Identifiable {
    let id = UUID()
    let filePath: String
    let messages: [Message]
    let projectPath: String?

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
        if lower.contains("gpt-4o") { return 128_000 }
        if lower.contains("o1") || lower.contains("o3") { return 200_000 }
        return 200_000  // default
    }

    var duration: TimeInterval {
        guard let start = startTime, let end = endTime else { return 0 }
        return end.timeIntervalSince(start)
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

struct SessionStats {
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
        gitDeletions: Int = 0
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

struct DailyStatPoint: Identifiable {
    let id = UUID()
    let date: Date
    let label: String  // "03/18"
    let sessions: Int
    let messages: Int
    let tokens: Int
    let cost: Double
    let activeMinutes: Double
}

// MARK: - Cost Estimation

struct ModelPricing {
    let inputPerMillion: Double       // $/M input tokens
    let outputPerMillion: Double      // $/M output tokens
    let cacheReadPerMillion: Double   // $/M cache read tokens
    let cacheCreatePerMillion: Double // $/M cache creation tokens
}

enum CostEstimator {
    // Claude API pricing (as of 2025)
    private static let pricing: [String: ModelPricing] = [
        // Claude
        "opus": ModelPricing(inputPerMillion: 15, outputPerMillion: 75, cacheReadPerMillion: 1.5, cacheCreatePerMillion: 18.75),
        "sonnet": ModelPricing(inputPerMillion: 3, outputPerMillion: 15, cacheReadPerMillion: 0.3, cacheCreatePerMillion: 3.75),
        "haiku": ModelPricing(inputPerMillion: 0.8, outputPerMillion: 4, cacheReadPerMillion: 0.08, cacheCreatePerMillion: 1.0),
        // OpenAI
        "gpt-4o": ModelPricing(inputPerMillion: 2.5, outputPerMillion: 10, cacheReadPerMillion: 1.25, cacheCreatePerMillion: 2.5),
        "gpt-4o-mini": ModelPricing(inputPerMillion: 0.15, outputPerMillion: 0.6, cacheReadPerMillion: 0.075, cacheCreatePerMillion: 0.15),
        "o1": ModelPricing(inputPerMillion: 15, outputPerMillion: 60, cacheReadPerMillion: 7.5, cacheCreatePerMillion: 15),
        "o3": ModelPricing(inputPerMillion: 10, outputPerMillion: 40, cacheReadPerMillion: 2.5, cacheCreatePerMillion: 10),
        "o3-mini": ModelPricing(inputPerMillion: 1.1, outputPerMillion: 4.4, cacheReadPerMillion: 0.55, cacheCreatePerMillion: 1.1),
        "o4-mini": ModelPricing(inputPerMillion: 1.1, outputPerMillion: 4.4, cacheReadPerMillion: 0.55, cacheCreatePerMillion: 1.1),
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
        // Claude models
        if lower.contains("opus") { return pricing["opus"]! }
        if lower.contains("haiku") { return pricing["haiku"]! }
        if lower.contains("sonnet") { return pricing["sonnet"]! }
        // OpenAI models
        if lower.contains("o4-mini") { return pricing["o4-mini"]! }
        if lower.contains("o3-mini") { return pricing["o3-mini"]! }
        if lower.contains("o3") { return pricing["o3"]! }
        if lower.contains("o1") { return pricing["o1"]! }
        if lower.contains("gpt-4o-mini") { return pricing["gpt-4o-mini"]! }
        if lower.contains("gpt-4o") { return pricing["gpt-4o"]! }
        // Default to sonnet pricing for unknown
        return pricing["sonnet"]!
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
