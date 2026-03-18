import Foundation

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
        "opus": ModelPricing(inputPerMillion: 15, outputPerMillion: 75, cacheReadPerMillion: 1.5, cacheCreatePerMillion: 18.75),
        "sonnet": ModelPricing(inputPerMillion: 3, outputPerMillion: 15, cacheReadPerMillion: 0.3, cacheCreatePerMillion: 3.75),
        "haiku": ModelPricing(inputPerMillion: 0.8, outputPerMillion: 4, cacheReadPerMillion: 0.08, cacheCreatePerMillion: 1.0),
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
        if lower.contains("opus") { return pricing["opus"]! }
        if lower.contains("haiku") { return pricing["haiku"]! }
        // Default to sonnet pricing
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
