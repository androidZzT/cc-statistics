import Foundation

/// 简单的国际化支持，跟随系统语言或用户设置
enum L10n {
    static var isChinese: Bool {
        let setting = UserDefaults.standard.string(forKey: "cc_stats_language") ?? "auto"
        switch setting {
        case "zh": return true
        case "en": return false
        default:
            let lang = Locale.preferredLanguages.first ?? ""
            return lang.hasPrefix("zh")
        }
    }

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

    // MARK: - Data Source
    static var allSources: String { isChinese ? "全部来源" : "All Sources" }

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
    static var search: String { isChinese ? "搜索会话..." : "Search..." }
    static var resumeSession: String { isChinese ? "恢复会话" : "Resume" }
    static var copied: String { isChinese ? "已复制" : "Copied" }

    // MARK: - Cost
    static var estimatedCost: String { isChinese ? "预估费用" : "Est. Cost" }
    static var cost: String { isChinese ? "费用" : "Cost" }

    // MARK: - Trend
    static var dailyTrend: String { isChinese ? "每日趋势" : "Daily Trend" }

    // MARK: - Status Bar
    static var statusBarDisplay: String { isChinese ? "状态栏显示" : "Display" }

    // MARK: - Export
    static var exportData: String { isChinese ? "导出数据" : "Export Data" }
    static var exportJSON: String { "JSON" }
    static var exportCSV: String { "CSV" }
    static var exported: String { isChinese ? "已导出" : "Exported" }
    static var exportedToDesktop: String { isChinese ? "已导出到桌面" : "Exported to Desktop" }

    // MARK: - Notification
    static var tokenAlert: String { isChinese ? "Token 用量提醒" : "Token Usage Alert" }
    static func tokenAlertBody(_ cost: String) -> String {
        isChinese ? "今日已消耗 \(cost)" : "Today's usage: \(cost)"
    }

    // MARK: - Settings
    static var settings: String { isChinese ? "设置" : "Settings" }
    static var general: String { isChinese ? "通用" : "General" }
    static var launchAtLogin: String { isChinese ? "开机启动" : "Launch at Login" }
    static var launchAtLoginDesc: String { isChinese ? "登录时自动启动 CC Stats" : "Automatically start CC Stats on login" }
    static var language: String { isChinese ? "语言" : "Language" }
    static var displayLanguage: String { isChinese ? "显示语言" : "Display Language" }
    static var followSystem: String { isChinese ? "跟随系统" : "Follow System" }
    static var about: String { isChinese ? "关于" : "About" }
    static var appearance: String { isChinese ? "外观" : "Appearance" }
    static var theme: String { isChinese ? "主题" : "Theme" }
    static var themeAuto: String { isChinese ? "跟随系统" : "System" }
    static var themeDark: String { isChinese ? "深色" : "Dark" }
    static var themeLight: String { isChinese ? "浅色" : "Light" }

    // MARK: - Alerts
    static var alerts: String { isChinese ? "用量预警" : "Usage Alerts" }
    static var dailyCostLimit: String { isChinese ? "单日费用上限" : "Daily Cost Limit" }
    static var dailyCostLimitDesc: String { isChinese ? "超过后状态栏变红提醒" : "Status bar turns red when exceeded" }
    static var weeklyCostLimit: String { isChinese ? "每周费用上限" : "Weekly Cost Limit" }
    static var weeklyCostLimitDesc: String { isChinese ? "7天累计超过后提醒" : "Alert when 7-day total exceeds limit" }
    static func alertExceeded(_ current: String, _ limit: String) -> String {
        isChinese ? "⚠️ 当前 \(current) 已超过 \(limit) 上限" : "⚠️ Current \(current) exceeded \(limit) limit"
    }
    static var alertDaily: String { isChinese ? "单日" : "Daily" }
    static var alertWeekly: String { isChinese ? "每周" : "Weekly" }

    // MARK: - Update
    static var newVersion: String { isChinese ? "发现新版本" : "New version" }
    static var updateNow: String { isChinese ? "立即更新" : "Update" }

    // MARK: - Loading
    static var loading: String { isChinese ? "加载中..." : "Loading..." }

    // MARK: - Efficiency
    static var efficiency: String { isChinese ? "效率评分" : "Efficiency" }
    static var codeOutput: String { isChinese ? "代码产出" : "Code Output" }
    static var precision: String { isChinese ? "指令精准" : "Precision" }
    static var aiUtilization: String { isChinese ? "AI 利用率" : "AI Util." }
    static var linesPerKToken: String { isChinese ? "行/K Token" : "lines/K" }
    static var tokensPerMsg: String { "Token/" + (isChinese ? "条" : "msg") }
    static var costPrediction: String { isChinese ? "成本预测" : "Cost Prediction" }
    static var dailyAvg: String { isChinese ? "日均" : "Daily Avg" }
    static var monthProjection: String { isChinese ? "月度预测" : "Monthly" }

    // MARK: - Metric Explanations
    static var helpSessions: String {
        isChinese
            ? "统计选定时间范围内的独立会话数量。一次 claude 命令启动或 --resume 恢复算一个会话。"
            : "Number of distinct sessions in the selected time range. Each claude command or --resume counts as one session."
    }
    static var helpInstructions: String {
        isChinese
            ? "用户发出的真实指令数（排除工具返回和系统消息）。反映你和 AI 的交互密度。"
            : "Real user messages sent (excludes tool results and system messages). Reflects your interaction density with AI."
    }
    static var helpDuration: String {
        isChinese
            ? "活跃时长 = AI 处理时间 + 用户操作时间。用户超过 5 分钟无操作的间隔不计入。不是首尾时间差，所以不会因 resume 跨天而虚高。"
            : "Active time = AI processing + user active time. Gaps > 5 min are excluded. Not wall-clock time, so resume across days won't inflate it."
    }
    static var helpCost: String {
        isChinese
            ? "根据各模型官方定价计算：input/output/cache token 分别按价计费。仅为估算，实际以账单为准。"
            : "Estimated from official model pricing: input/output/cache tokens billed separately. For reference only — check your actual bill."
    }
    static var helpToolCalls: String {
        isChinese
            ? "AI 调用的工具次数，按工具类型分组排名。Skill 和 MCP 工具会展开为具体名称。"
            : "Tool invocations by AI, grouped and ranked by type. Skill and MCP tools are expanded to specific names."
    }
    static var helpDevTime: String {
        isChinese
            ? "AI 处理：每轮从用户发消息到 AI 最后一条响应的时间之和。\n用户活跃：上一轮 AI 结束到下一轮用户消息的间隔（≤5分钟才计入）。\nAI 占比 = AI 处理 / (AI 处理 + 用户活跃)。"
            : "AI Processing: sum of time from user message to AI's last response per turn.\nUser Active: gap between AI's last response and next user message (only if ≤5min).\nAI Ratio = AI / (AI + User)."
    }
    static var helpCodeChanges: String {
        isChinese
            ? "Git 已提交：会话期间 git commit 的实际变更，按语言分类。AI commit 通过 Co-Authored-By 标记识别。\nAI 工具变更：来自 Edit/Write 工具调用的代码行数（可能未提交）。"
            : "Git Committed: actual changes from git commits during session, by language. AI commits detected via Co-Authored-By markers.\nAI Tool Changes: lines from Edit/Write tool calls (may not be committed)."
    }
    static var helpTokenUsage: String {
        isChinese
            ? "输入：发送给模型的 token 数。输出：模型生成的 token 数。\n缓存读：命中 prompt cache 的 token（按 0.1x 计费）。\n缓存写：新建 cache 的 token（按 1.25x 计费）。"
            : "Input: tokens sent to model. Output: tokens generated.\nCache Read: prompt cache hits (billed at 0.1x).\nCache Write: new cache entries (billed at 1.25x)."
    }
    static var helpEfficiency: String {
        isChinese
            ? "代码产出(40分): 行/K Token\n指令精准(30分): Token/条\nAI利用率(30分): AI时间占比\nS≥90 A≥75 B≥60 C≥40 D<40"
            : "Code(40): lines/K Token\nPrecision(30): Token/msg\nAI Util(30): AI time ratio\nS≥90 A≥75 B≥60 C≥40 D<40"
    }
    static var helpCostPrediction: String {
        isChinese
            ? "日均费用 = 总费用 / 有数据的天数。\n月度预测 = 日均 × 30。\n超过 $1000 显示红色警告。"
            : "Daily Avg = total cost / days with data.\nMonthly = daily avg × 30.\nShown in red if > $1000."
    }

    // MARK: - Process Manager
    static var processes: String { isChinese ? "进程管理" : "Processes" }
    static var active: String { isChinese ? "活跃" : "Active" }
    static var idle: String { isChinese ? "空闲" : "Idle" }
    static var cleanIdle: String { isChinese ? "清理空闲" : "Clean Idle" }
    static var killed: String { isChinese ? "已清理" : "Cleaned" }
}
