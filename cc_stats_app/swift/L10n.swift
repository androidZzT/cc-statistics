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

    // MARK: - Usage Quota
    static var rateLimit: String { isChinese ? "用量额度" : "Usage Quota" }
    static var apiToken: String { isChinese ? "Session Token" : "Session Token" }
    static var apiTokenDesc: String { isChinese ? "从浏览器获取 claude.ai 的登录凭证，用于查询订阅额度。这不是 API Key。" : "Enter your claude.ai session token to view subscription quota usage (not an API key, never uploaded)" }
    static var apiTokenPlaceholder: String { isChinese ? "粘贴 OAuth Token..." : "Paste OAuth token..." }
    static var apiTokenHowTo: String { isChinese ? "获取方式：登录 claude.ai → 浏览器开发者工具 → Network → 复制任意请求的 Authorization 头部值" : "How to get: Log in to claude.ai → Open DevTools → Network tab → Copy the Authorization header value" }
    static var fiveHourUsage: String { isChinese ? "5小时" : "5-Hour" }
    static var sevenDayUsage: String { isChinese ? "7天" : "7-Day" }
    static var resetsAt: String { isChinese ? "重置于" : "Resets" }
    static var rateLimitUnavailable: String { isChinese ? "未配置 Token" : "Token not configured" }
    static var helpRateLimit: String { isChinese ? "Claude Pro/Max 订阅的速率配额用量" : "Claude Pro/Max subscription rate quota usage" }

    // Codex 用量额度（OpenAI 后端写到 JSONL 的 snapshot，无需 API token）
    static var codexRateLimit: String { isChinese ? "Codex 用量额度" : "Codex Usage Quota" }
    static var codexFiveHourUsage: String { isChinese ? "Codex 5小时" : "Codex 5h" }
    static var codexSevenDayUsage: String { isChinese ? "Codex 7天" : "Codex 7d" }
    static var helpCodexRateLimit: String {
        isChinese
            ? "Codex 订阅 5h / 7d 滚动窗口用量百分比，由 Codex CLI 缓存到本地 JSONL（无需配置 token）。"
            : "Codex subscription 5h / 7d rolling-window usage, read from the snapshot Codex CLI cached into local JSONL (no token required)."
    }

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
        isChinese ? "打开 Claude Code 的次数" : "Times Claude Code was opened"
    }
    static var helpInstructions: String {
        isChinese ? "你发送的消息数" : "Messages you sent"
    }
    static var helpDuration: String {
        isChinese ? "你和 AI 都在工作的时间" : "Time you and AI were active"
    }
    static var helpCost: String {
        isChinese ? "按官方定价估算，仅供参考" : "Estimated cost, for reference"
    }
    static var helpToolCalls: String {
        isChinese ? "AI 使用各类工具的次数" : "How often AI used each tool"
    }
    static var helpDevTime: String {
        isChinese ? "AI 处理和你思考的时间拆分" : "AI processing vs your thinking time"
    }
    static var helpCodeChanges: String {
        isChinese ? "AI 帮你写了多少代码" : "How much code AI wrote for you"
    }
    static var helpTokenUsage: String {
        isChinese ? "消耗的 token 明细" : "Token consumption details"
    }
    static var helpEfficiency: String {
        isChinese ? "每消耗 1K token 产出多少代码" : "Code output per 1K tokens spent"
    }
    static var helpCostPrediction: String {
        isChinese ? "按当前用量预测月度花费" : "Projected monthly cost at current rate"
    }

    // MARK: - Process Manager
    static var processes: String { isChinese ? "进程管理" : "Processes" }
    static var active: String { isChinese ? "活跃" : "Active" }
    static var idle: String { isChinese ? "空闲" : "Idle" }
    static var cleanIdle: String { isChinese ? "清理空闲" : "Clean Idle" }
    static var killed: String { isChinese ? "已清理" : "Cleaned" }

    // MARK: - Notifications
    static var notifications: String { isChinese ? "通知" : "Notifications" }
    static var notifySessionComplete: String { isChinese ? "会话完成通知" : "Session Complete" }
    static var notifySessionCompleteDesc: String { isChinese ? "Claude Code 任务结束时提醒" : "Notify when Claude Code task finishes" }
    static var notifyCostAlert: String { isChinese ? "费用预警通知" : "Cost Alert" }
    static var notifyCostAlertDesc: String { isChinese ? "费用超过上限时告警" : "Alert when cost exceeds limit" }
    static var notifyPermission: String { isChinese ? "权限请求通知" : "Permission Request" }
    static var notifyPermissionDesc: String { isChinese ? "需要确认权限时提醒" : "Notify when permission is needed" }
    static var notifySmartSuppress: String { isChinese ? "智能抑制" : "Smart Suppress" }
    static var notifySmartSuppressDesc: String { isChinese ? "终端有焦点时不弹通知" : "Don't notify when terminal is focused" }
    static var notifyWebhook: String { isChinese ? "Webhook 转发" : "Webhook Forward" }
    static var notifyWebhookDesc: String { isChinese ? "同时发送到飞书/Slack/钉钉" : "Also send to Feishu/Slack/DingTalk" }
    static var notifyWebhookPlaceholder: String { isChinese ? "粘贴 Webhook URL..." : "Paste webhook URL..." }
    static var installHooks: String { isChinese ? "安装 Hooks" : "Install Hooks" }
    static var installHooksDesc: String { isChinese ? "安装 Claude Code hooks 启用通知" : "Install Claude Code hooks to enable notifications" }
    static var hooksInstalled: String { isChinese ? "已安装" : "Installed" }
    static var hooksNotInstalled: String { isChinese ? "未安装" : "Not Installed" }
    static var testNotification: String { isChinese ? "测试通知" : "Test" }
    static var notifySent: String { isChinese ? "已发送" : "Sent" }

    // MARK: - Dashboard Modules
    static var dashboardModules: String { isChinese ? "面板模块" : "Dashboard Modules" }
    static var dashboardModulesDesc: String { isChinese ? "选择要在面板上显示的模块" : "Choose which modules to show on dashboard" }
    static var coreModules: String { isChinese ? "核心模块（始终显示）" : "Core modules (always shown)" }
    static var optionalModules: String { isChinese ? "可选模块" : "Optional modules" }
    static var headerCardsLabel: String { isChinese ? "概览卡片" : "Header Cards" }
    static var tokenUsageLabel: String { isChinese ? "Token 统计" : "Token Usage" }
    static var trendChartLabel: String { isChinese ? "每日趋势图" : "Daily Trend" }
}
