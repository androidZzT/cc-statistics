import Foundation

/// 简单的国际化支持，跟随系统语言
enum L10n {
    private static let isChinese: Bool = {
        let lang = Locale.preferredLanguages.first ?? ""
        return lang.hasPrefix("zh")
    }()

    // MARK: - Time Filter
    static var today: String { isChinese ? "今天" : "Today" }
    static var week: String { isChinese ? "本周" : "Week" }
    static var month: String { isChinese ? "本月" : "Month" }
    static var allTime: String { isChinese ? "全部" : "All" }

    // MARK: - Header Cards
    static var sessions: String { isChinese ? "会话" : "Sessions" }
    static var instructions: String { isChinese ? "指令" : "Instructions" }
    static var duration: String { isChinese ? "时长" : "Duration" }
    static var token: String { "Token" }

    // MARK: - Sections
    static var toolCalls: String { isChinese ? "工具调用" : "Tool Calls" }
    static var devTime: String { isChinese ? "开发时间" : "Dev Time" }
    static var codeChanges: String { isChinese ? "代码变更" : "Code Changes" }
    static var tokenUsage: String { isChinese ? "Token 用量" : "Token Usage" }

    // MARK: - Dev Time
    static var aiRatio: String { isChinese ? "AI 占比" : "AI Ratio" }
    static var totalTime: String { isChinese ? "总时间" : "Total" }
    static var aiProcessing: String { isChinese ? "AI 处理" : "AI" }
    static var userActive: String { isChinese ? "用户活跃" : "User" }

    // MARK: - Code Changes
    static var commits: String { isChinese ? "次提交" : "commits" }
    static var noCodeChanges: String { isChinese ? "未检测到代码变更" : "No code changes detected" }

    // MARK: - Token
    static var input: String { isChinese ? "输入" : "Input" }
    static var output: String { isChinese ? "输出" : "Output" }
    static var cacheRead: String { isChinese ? "缓存读" : "Cache Read" }
    static var cacheWrite: String { isChinese ? "缓存写" : "Cache Write" }
    static var cache: String { isChinese ? "缓存" : "Cache" }

    // MARK: - Project
    static var allProjects: String { isChinese ? "所有项目" : "All Projects" }

    // MARK: - Footer
    static var conversation: String { isChinese ? "对话" : "Chat" }
    static var refresh: String { isChinese ? "刷新" : "Refresh" }

    // MARK: - Empty/Loading
    static var noData: String { isChinese ? "暂无会话数据" : "No session data" }
    static var noDataHint: String { isChinese ? "启动 Claude Code 会话即可查看统计数据。" : "Start a Claude Code session to see statistics." }

    // MARK: - Menu
    static var showDashboard: String { isChinese ? "显示仪表盘" : "Show Dashboard" }
    static var showChat: String { isChinese ? "显示对话" : "Show Chat" }
    static var quit: String { isChinese ? "退出" : "Quit" }

    // MARK: - Conversation
    static var sessionList: String { isChinese ? "会话列表" : "Sessions" }
    static var noMessages: String { isChinese ? "暂无消息" : "No messages" }
    static var messagesCount: String { isChinese ? "条消息" : "messages" }
    static var toolCallsCount: String { isChinese ? "次工具调用" : "tool calls" }
    static var you: String { isChinese ? "你" : "You" }
    static var assistant: String { isChinese ? "助手" : "Assistant" }
    static var selectSession: String { isChinese ? "请选择一个会话" : "Select a session" }
}
