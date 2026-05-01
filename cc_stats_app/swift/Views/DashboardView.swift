import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - DashboardView

struct DashboardView: View {
    @ObservedObject var viewModel: StatsViewModel
    @State private var toastMessage: String?
    @State private var processes: [ProcessInfo2] = []
    @State private var trendMetric: TrendMetric = .cost
    @State private var activeGuide: String?
    @State private var guideAnchors: [String: Anchor<CGRect>] = [:]
    @State private var moduleVersion: Int = 0

    enum TrendMetric: String, CaseIterable {
        case cost, tokens, sessions, activeTime

        var label: String {
            switch self {
            case .cost: return L10n.isChinese ? "费用" : "Cost"
            case .tokens: return "Token"
            case .sessions: return L10n.isChinese ? "会话" : "Sessions"
            case .activeTime: return L10n.isChinese ? "时长" : "Time"
            }
        }

        func value(for point: DailyStatPoint) -> Double {
            switch self {
            case .cost: return point.cost
            case .tokens: return Double(point.tokens)
            case .sessions: return Double(point.sessions)
            case .activeTime: return point.activeMinutes
            }
        }

        func format(_ value: Double) -> String {
            switch self {
            case .cost: return CostEstimator.formatCost(value)
            case .tokens:
                if value >= 1_000_000 { return String(format: "%.0fM", value / 1_000_000) }
                if value >= 1_000 { return String(format: "%.0fK", value / 1_000) }
                return String(format: "%.0f", value)
            case .sessions: return String(format: "%.0f", value)
            case .activeTime:
                let h = Int(value) / 60
                let m = Int(value) % 60
                return h > 0 ? "\(h)h\(m)m" : "\(m)m"
            }
        }

        var color: Color {
            switch self {
            case .cost: return Theme.amber
            case .tokens: return Theme.purple
            case .sessions: return Theme.cyan
            case .activeTime: return Theme.green
            }
        }
    }

    var body: some View {
        ZStack {
        Group {
            if viewModel.showSettings {
                SettingsView(
                    isPresented: $viewModel.showSettings,
                    onLanguageChanged: { viewModel.languageVersion += 1 },
                    onThemeChanged: { viewModel.themeMode = $0 },
                    onModulesChanged: { moduleVersion += 1 }
                )
            } else {
                VStack(spacing: 0) {
                    // Top toolbar
                    toolbarSection

                    // Alert banner
                    if !viewModel.alertMessages.isEmpty {
                        VStack(spacing: 4) {
                            ForEach(viewModel.alertMessages, id: \.self) { msg in
                                HStack(spacing: 6) {
                                    Text(msg)
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(.white)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(Theme.red.opacity(0.85))
                            }
                        }
                    }

                    if viewModel.selectedSource == .cursor {
                        cursorContent
                    } else {
                        claudeCodeContent
                    }

                    // Bottom bar
                    footerSection
                }
                .id("\(viewModel.languageVersion)-\(moduleVersion)")
            }
        }

            // Toast overlay
            if let msg = toastMessage {
                VStack {
                    Spacer()
                    Text(msg)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Theme.green.opacity(0.9))
                        )
                        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.bottom, 16)
                }
                .animation(.easeInOut(duration: 0.25), value: toastMessage != nil)
            }

            // Guide overlay
            if let guideId = activeGuide {
                GuideOverlay(
                    stepId: guideId,
                    title: guideTitle(for: guideId),
                    message: guideMessage(for: guideId),
                    arrowEdge: .top,
                    anchors: guideAnchors,
                    onDismiss: {
                        GuideManager.markShown("rate_limit_setup")
                        activeGuide = nil
                    }
                )
                .zIndex(100)
            }

            // Loading overlay
            ZStack {
                if viewModel.isLoading && viewModel.stats != nil {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()

                    VStack(spacing: 16) {
                        TimelineView(.animation) { timeline in
                            Circle()
                                .trim(from: 0, to: 0.7)
                                .stroke(Theme.cyan, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                .frame(width: 40, height: 40)
                                .rotationEffect(.degrees(timeline.date.timeIntervalSince1970.truncatingRemainder(dividingBy: 3.6) * 100))
                        }

                        Text(L10n.loading)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Theme.textPrimary)
                    }
                    .padding(28)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Theme.cardBackground.opacity(0.95))
                    )
                }
            }
        }
        .frame(width: 480)
        .frame(maxHeight: 640)
        .background(Theme.background)
        .animation(.easeInOut(duration: 0.15), value: viewModel.isLoading)
        .onPreferenceChange(GuideAnchorKey.self) { guideAnchors = $0 }
        .onAppear { triggerGuideIfNeeded() }
        .onChange(of: viewModel.stats != nil) { _ in triggerGuideIfNeeded() }
    }


    // MARK: - Guide

    private func triggerGuideIfNeeded() {
        // Only show guides when dashboard is visible and data is loaded
        guard viewModel.stats != nil, !viewModel.showSettings else { return }

        // Rate limit guide: show once if token not configured
        let tokenConfigured = !(UserDefaults.standard.string(forKey: UsageAPI.tokenKey) ?? "").isEmpty
        if !tokenConfigured && !GuideManager.hasShown("rate_limit_setup") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                activeGuide = "settings_gear"
            }
        }
    }

    private func guideTitle(for id: String) -> String {
        switch id {
        case "settings_gear":
            return L10n.isChinese ? "查看 Claude 用量额度" : "View Claude Usage Quota"
        default:
            return ""
        }
    }

    private func guideMessage(for id: String) -> String {
        switch id {
        case "settings_gear":
            return L10n.isChinese
                ? "在设置中粘贴 OAuth Token，即可实时显示 5 小时 / 7 天用量百分比。Token 仅用于本地查询，不会上传。"
                : "Paste your OAuth token in Settings to see real-time 5-hour / 7-day usage. Token is only used locally."
        default:
            return ""
        }
    }

    // MARK: - Tab Switcher

    private var tabSwitcher: some View {
        HStack(spacing: 0) {
            ForEach(StatsViewModel.StatsTab.allCases, id: \.self) { tab in
                HStack(spacing: 5) {
                    Image(systemName: tab == .claudeCode ? "sparkles" : "cursorarrow.rays")
                        .font(.system(size: 10, weight: .bold))
                    Text(tab.rawValue)
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(viewModel.activeTab == tab ? Theme.textPrimary : Theme.textTertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    viewModel.activeTab == tab
                        ? Theme.cardBackground
                        : Color.clear
                )
                .overlay(
                    Rectangle()
                        .fill(viewModel.activeTab == tab ? Theme.cyan : Color.clear)
                        .frame(height: 2),
                    alignment: .bottom
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    viewModel.selectSource(tab == .claudeCode ? .claudeCode : .cursor)
                }
            }
        }
        .background(Theme.background)
        .overlay(
            Rectangle().fill(Theme.border).frame(height: 1),
            alignment: .bottom
        )
    }

    // MARK: - Claude Code Content

    private var claudeCodeContent: some View {
        Group {
            if viewModel.isLoading && viewModel.stats == nil {
                loadingState
            } else if let stats = viewModel.stats {
                claudeCodeStatsContent(stats: stats)
            } else {
                emptyState
            }
        }
    }

    @ViewBuilder
    private func claudeCodeStatsContent(stats: SessionStats) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 14) {
                // Core modules (always shown)
                headerCards(stats: stats)
                tokenUsageSection(stats: stats)
                trendChart

                // Optional modules (controlled by settings)
                if DashboardModule.rateLimit.isVisible {
                    rateLimitSection
                }
                if DashboardModule.developmentTime.isVisible {
                    developmentTimeSection(stats: stats)
                }
                if DashboardModule.codeChanges.isVisible {
                    codeChangesSection(stats: stats)
                }
                if DashboardModule.toolCalls.isVisible {
                    toolCallsSection(stats: stats)
                }
                if DashboardModule.skillStats.isVisible {
                    skillStatsSection(stats: stats)
                }
                if DashboardModule.efficiency.isVisible {
                    efficiencySection(stats: stats)
                }
                if DashboardModule.costPrediction.isVisible {
                    costPredictionSection(stats: stats)
                }
                if DashboardModule.processMonitor.isVisible {
                    processSection
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 14)
        }
    }

    // MARK: - Cursor Content

    private var cursorContent: some View {
        CursorStatsView(cursorStats: viewModel.cursorStats, isLoading: viewModel.isLoading)
    }

    // MARK: - Toolbar

    private var toolbarSection: some View {
        VStack(spacing: 0) {
            // Row 1: Project selector + export + settings
            HStack(spacing: 6) {
                // Project selector
                Menu {
                    Button {
                        viewModel.selectProject(nil)
                    } label: {
                        HStack {
                            Text(L10n.allProjects)
                            if viewModel.selectedProject == nil {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    Divider()
                    ForEach(viewModel.projects) { project in
                        Button {
                            viewModel.selectProject(project)
                        } label: {
                            HStack {
                                Text(project.name)
                                if viewModel.selectedProject == project {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Theme.cyan)
                        Text(viewModel.selectedProject?.name ?? L10n.allProjects)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(Theme.textTertiary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Theme.cardBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Theme.border, lineWidth: 1)
                            )
                    )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                // Source filter
                Menu {
                    ForEach(DataSource.allCases) { source in
                        Button {
                            viewModel.selectSource(source)
                        } label: {
                            HStack {
                                Image(systemName: source.icon)
                                Text(source.displayName)
                                if viewModel.selectedSource == source {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        sourceIcon(viewModel.selectedSource, size: 12)
                            .foregroundColor(Theme.purple)
                        Text(viewModel.selectedSource.displayName)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundColor(Theme.textTertiary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Theme.cardBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(Theme.border, lineWidth: 1)
                            )
                    )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Spacer()

                // Export button
                if let stats = viewModel.stats {
                    Menu {
                        Button(L10n.exportJSON) { exportJSON(stats: stats) }
                        Button(L10n.exportCSV) { exportCSV(stats: stats) }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Theme.textSecondary)
                            .frame(width: 24, height: 24)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                // Settings button (tight spacing with export)
                Button {
                    viewModel.showSettings.toggle()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(viewModel.showSettings ? Theme.cyan : Theme.textSecondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .guideAnchor("settings_gear")
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 6)

            // Row 2: Time filter pills
            HStack {
                timeFilterPills
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .background(Theme.background)
        .overlay(
            Rectangle()
                .fill(Theme.border)
                .frame(height: 1),
            alignment: .bottom
        )
    }

    private var timeFilterPills: some View {
        HStack(spacing: 2) {
            ForEach(TimeFilter.allCases, id: \.self) { filter in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.setTimeFilter(filter)
                    }
                } label: {
                    Text(filter.label)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(
                            viewModel.timeFilter == filter
                                ? Theme.background
                                : Theme.textSecondary
                        )
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(
                                    viewModel.timeFilter == filter
                                        ? Theme.cyan
                                        : Color.clear
                                )
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.cardBackground)
        )
    }

    // MARK: - Header Cards

    private func headerCards(stats: SessionStats) -> some View {
        HStack(spacing: 8) {
            StatCard(
                icon: "terminal.fill",
                title: L10n.sessions,
                value: "\(stats.sessionCount)",
                accentColor: Theme.cyan,
                helpText: L10n.helpSessions
            )
            StatCard(
                icon: "text.bubble.fill",
                title: L10n.instructions,
                value: "\(stats.userInstructions)",
                accentColor: Theme.purple,
                helpText: L10n.helpInstructions
            )
            StatCard(
                icon: "clock.fill",
                title: L10n.duration,
                value: formatDuration(stats.totalDuration),
                accentColor: Theme.green,
                helpText: L10n.helpDuration
            )
            StatCard(
                icon: "dollarsign.circle.fill",
                title: L10n.estimatedCost,
                value: CostEstimator.formatCost(stats.estimatedCost),
                accentColor: Theme.amber,
                helpText: L10n.helpCost
            )
        }
    }

    // MARK: - Tool Calls Section

    private func toolCallsSection(stats: SessionStats) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(icon: "hammer.fill", title: L10n.toolCalls, accentColor: Theme.cyan, helpText: L10n.helpToolCalls)

                let sortedTools = stats.toolCalls
                    .sorted(by: { $0.value > $1.value })
                    .prefix(10)
                let maxCount = sortedTools.first?.value ?? 1

                VStack(spacing: 4) {
                    ForEach(Array(sortedTools.enumerated()), id: \.offset) { index, tool in
                        BarChartRow(
                            label: tool.key,
                            value: tool.value,
                            maxValue: maxCount,
                            color: Theme.barGradientColors[index % Theme.barGradientColors.count],
                            rank: index + 1
                        )
                    }
                }
            }
        }
    }

    // MARK: - Skill Stats Section

    @ViewBuilder
    private func skillStatsSection(stats: SessionStats) -> some View {
        let sortedSkills = stats.skillStats.values
            .sorted { $0.callCount > $1.callCount }

        if !sortedSkills.isEmpty {
            GlassCard {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(
                        icon: "command.circle.fill",
                        title: L10n.isChinese ? "Skill 使用" : "Skill Usage",
                        accentColor: Theme.pink,
                        helpText: L10n.isChinese
                            ? "各 Skill 的调用次数和成功率"
                            : "Call count and success rate for each Skill"
                    )

                    let maxCount = sortedSkills.first?.callCount ?? 1

                    VStack(spacing: 4) {
                        ForEach(Array(sortedSkills.prefix(10).enumerated()), id: \.offset) { index, skill in
                            HStack(spacing: 6) {
                                Text(skill.name)
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundColor(Theme.textSecondary)
                                    .frame(width: 90, alignment: .trailing)
                                    .lineLimit(1)

                                GeometryReader { geo in
                                    let width = max(2, geo.size.width * CGFloat(skill.callCount) / CGFloat(maxCount))
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Theme.barGradientColors[index % Theme.barGradientColors.count].opacity(0.5))
                                        .frame(width: width)
                                }
                                .frame(height: 14)

                                Text("\(skill.callCount)")
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundColor(Theme.textTertiary)
                                    .frame(width: 28, alignment: .trailing)

                                // Success rate badge
                                if let rate = skill.successRate {
                                    Text("\(rate)%")
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundColor(rate >= 90 ? Theme.green : rate >= 70 ? Theme.amber : Theme.red)
                                        .frame(width: 32, alignment: .trailing)
                                } else {
                                    Text("—")
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundColor(Theme.textTertiary)
                                        .frame(width: 32, alignment: .trailing)
                                }
                            }
                            .frame(height: 18)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Development Time Section

    private func developmentTimeSection(stats: SessionStats) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(icon: "chart.pie.fill", title: L10n.devTime, accentColor: Theme.green, helpText: L10n.helpDevTime)

                HStack(spacing: 20) {
                    // Activity ring: AI processing / active time (AI + user)
                    let activeTime = stats.aiProcessingTime + stats.userActiveTime
                    let aiRate = activeTime > 0
                        ? stats.aiProcessingTime / activeTime
                        : 0

                    ActivityRing(
                        progress: aiRate,
                        lineWidth: 8,
                        size: 90,
                        gradientColors: [Theme.cyan, Theme.purple],
                        label: L10n.aiRatio
                    )

                    // Time breakdown
                    VStack(spacing: 8) {
                        TimeBreakdownRow(
                            icon: "clock.fill",
                            label: L10n.totalTime,
                            value: formatDuration(stats.totalDuration),
                            color: Theme.cyan
                        )
                        Divider()
                            .background(Theme.border)
                        TimeBreakdownRow(
                            icon: "cpu",
                            label: L10n.aiProcessing,
                            value: formatDuration(stats.aiProcessingTime),
                            color: Theme.purple
                        )
                        Divider()
                            .background(Theme.border)
                        TimeBreakdownRow(
                            icon: "person.fill",
                            label: L10n.userActive,
                            value: formatDuration(stats.userActiveTime),
                            color: Theme.green
                        )
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    // MARK: - Code Changes Section

    private func codeChangesSection(stats: SessionStats) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionHeader(icon: "chevron.left.forwardslash.chevron.right", title: L10n.codeChanges, accentColor: Theme.pink, helpText: L10n.helpCodeChanges)
                    Spacer()
                    let totalAdd = stats.gitAdditions + stats.codeChanges.reduce(0) { $0 + $1.additions }
                    let totalDel = stats.gitDeletions + stats.codeChanges.reduce(0) { $0 + $1.deletions }
                    HStack(spacing: 8) {
                        Text("+\(totalAdd)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(Theme.green)
                        Text("-\(totalDel)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(Theme.red)
                    }
                }

                if stats.gitCommits > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 9))
                            .foregroundColor(Theme.textTertiary)
                        Text("\(stats.gitCommits) \(L10n.commits)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(Theme.textSecondary)
                    }
                }

                // Aggregate code changes by language
                let langStats = aggregateByLanguage(stats.codeChanges)
                let sorted = langStats.sorted { ($0.additions + $0.deletions) > ($1.additions + $1.deletions) }

                VStack(spacing: 2) {
                    ForEach(Array(sorted.prefix(8).enumerated()), id: \.offset) { _, change in
                        LanguageDot(
                            language: change.language,
                            additions: change.additions,
                            deletions: change.deletions
                        )
                    }
                }

                if sorted.isEmpty {
                    Text(L10n.noCodeChanges)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                        .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - Token Usage Section

    private func tokenUsageSection(stats: SessionStats) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(icon: "circle.hexagonpath.fill", title: L10n.tokenUsage, accentColor: Theme.amber, helpText: L10n.helpTokenUsage)

                let tokenEntries = stats.tokenUsage.sorted(by: { $0.value.totalTokens > $1.value.totalTokens })

                ForEach(Array(tokenEntries.enumerated()), id: \.offset) { index, entry in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(entry.key)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(Theme.textPrimary)
                            Spacer()
                            Text(CostEstimator.formatCost(CostEstimator.estimateCostForModel(entry.key, detail: entry.value)))
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(Theme.amber)
                            Text(formatTokens(entry.value.totalTokens))
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(Theme.textSecondary)
                        }

                        TokenStackedBar(
                            segments: [
                                (label: L10n.input, value: entry.value.inputTokens, color: Theme.cyan),
                                (label: L10n.output, value: entry.value.outputTokens, color: Theme.purple),
                                (label: L10n.cacheRead, value: entry.value.cacheReadInputTokens, color: Theme.green),
                                (label: L10n.cacheWrite, value: entry.value.cacheCreationInputTokens, color: Theme.amber),
                            ],
                            height: 10
                        )
                    }
                    .padding(.vertical, 4)

                    if index < tokenEntries.count - 1 {
                        Divider()
                            .background(Theme.border)
                    }
                }

                // Summary pills
                HStack(spacing: 6) {
                    TokenPill(label: L10n.input, count: stats.totalInputTokens, color: Theme.cyan)
                    TokenPill(label: L10n.output, count: stats.totalOutputTokens, color: Theme.purple)
                    TokenPill(label: L10n.cache, count: stats.totalCacheReadTokens + stats.totalCacheCreationTokens, color: Theme.green)
                    Spacer()
                    Text(CostEstimator.formatCost(stats.estimatedCost))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(Theme.amber)
                }
            }
        }
    }

    // MARK: - Trend Chart

    private var trendChart: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                // Header with metric picker
                HStack {
                    SectionHeader(icon: "chart.xyaxis.line", title: L10n.dailyTrend, accentColor: Theme.cyan)

                    HStack(spacing: 2) {
                        ForEach(TrendMetric.allCases, id: \.self) { metric in
                            Button {
                                trendMetric = metric
                            } label: {
                                Text(metric.label)
                                    .font(.system(size: 8, weight: trendMetric == metric ? .bold : .medium))
                                    .foregroundColor(trendMetric == metric ? metric.color : Theme.textTertiary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .fill(trendMetric == metric ? metric.color.opacity(0.12) : Color.clear)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                let data = viewModel.dailyStats.filter { trendMetric.value(for: $0) > 0 || $0.sessions > 0 }
                if data.isEmpty {
                    Text(L10n.noData)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                        .padding(.vertical, 8)
                } else {
                    let maxVal = viewModel.dailyStats.map { trendMetric.value(for: $0) }.max() ?? 1
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(viewModel.dailyStats) { point in
                            let val = trendMetric.value(for: point)
                            VStack(spacing: 2) {
                                if val > 0 {
                                    Text(trendMetric.format(val))
                                        .font(.system(size: 7, weight: .medium, design: .monospaced))
                                        .foregroundColor(trendMetric.color)
                                }
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(
                                        LinearGradient(
                                            colors: [trendMetric.color.opacity(0.6), trendMetric.color.opacity(0.9)],
                                            startPoint: .bottom,
                                            endPoint: .top
                                        )
                                    )
                                    .frame(height: max(2, CGFloat(val / maxVal) * 60))
                                Text(point.label.suffix(3))
                                    .font(.system(size: 7))
                                    .foregroundColor(Theme.textTertiary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: 90)
                }
            }
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            if let lastRefresh = viewModel.lastRefreshed {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 9))
                    .foregroundColor(Theme.textTertiary)
                Text("已更新 \(lastRefresh, style: .relative)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Theme.textTertiary)
            }

            Spacer()

            Button {
                viewModel.toggleConversationPanel()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text(L10n.conversation)
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundColor(Theme.purple)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Theme.purple.opacity(0.1))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Theme.purple.opacity(0.2), lineWidth: 0.5)
                        )
                )
            }
            .buttonStyle(.plain)

            Button {
                viewModel.refresh()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(viewModel.isLoading ? 360 : 0))
                        .animation(
                            viewModel.isLoading
                                ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                                : .default,
                            value: viewModel.isLoading
                        )
                    Text(L10n.refresh)
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundColor(Theme.cyan)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Theme.cyan.opacity(0.1))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Theme.cyan.opacity(0.2), lineWidth: 0.5)
                        )
                )
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isLoading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.background)
        .overlay(
            Rectangle()
                .fill(Theme.border)
                .frame(height: 1),
            alignment: .top
        )
    }

    // MARK: - States

    private var loadingState: some View {
        VStack(spacing: 14) {
            ForEach(0..<4, id: \.self) { _ in
                ShimmerView()
                    .frame(height: 60)
            }
        }
        .padding(16)
        .frame(maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar.xaxis.ascending")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Theme.cyan, Theme.purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Text(L10n.noData)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Text(L10n.noDataHint)
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: - Efficiency Section

    private func efficiencySection(stats: SessionStats) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(icon: "gauge.with.dots.needle.33percent", title: L10n.efficiency, accentColor: Theme.amber, helpText: L10n.helpEfficiency)

                // Grade badge
                HStack(spacing: 12) {
                    let grade = stats.efficiencyGrade
                    let score = stats.efficiencyTotalScore
                    let gradeColor = (grade == "S" || grade == "A") ? Theme.green :
                                     grade == "B" ? Theme.amber : Theme.red

                    Text(grade)
                        .font(.system(size: 28, weight: .black, design: .rounded))
                        .foregroundColor(gradeColor)
                        .frame(width: 50, height: 50)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(gradeColor.opacity(0.15))
                        )

                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(score)/100")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundColor(Theme.textPrimary)

                        // Score bar
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Theme.textTertiary.opacity(0.2))
                                    .frame(height: 6)
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(
                                        LinearGradient(
                                            colors: [gradeColor.opacity(0.7), gradeColor],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .frame(width: geo.size.width * CGFloat(score) / 100.0, height: 6)
                            }
                        }
                        .frame(height: 6)
                    }

                    Spacer()
                }

                // Dimension breakdown
                VStack(spacing: 6) {
                    efficiencyRow(
                        label: L10n.codeOutput,
                        value: String(format: "%.2f %@", stats.codePerKToken, L10n.linesPerKToken),
                        score: stats.efficiencyCodeScore,
                        maxScore: 40,
                        color: Theme.cyan
                    )
                    efficiencyRow(
                        label: L10n.precision,
                        value: formatTokens(stats.avgTokensPerInstruction) + " " + L10n.tokensPerMsg,
                        score: stats.efficiencyPrecisionScore,
                        maxScore: 30,
                        color: Theme.purple
                    )
                    efficiencyRow(
                        label: L10n.aiUtilization,
                        value: String(format: "%.0f%%", stats.aiUtilizationRate),
                        score: stats.efficiencyUtilScore,
                        maxScore: 30,
                        color: Theme.green
                    )
                }
            }
        }
    }

    private func efficiencyRow(label: String, value: String, score: Int, maxScore: Int, color: Color) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Theme.textSecondary)
                .frame(width: 60, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.textTertiary.opacity(0.15))
                        .frame(height: 4)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color)
                        .frame(width: geo.size.width * CGFloat(score) / CGFloat(maxScore), height: 4)
                }
            }
            .frame(height: 4)

            Text(value)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(Theme.textTertiary)
                .frame(width: 90, alignment: .trailing)

            Text("\(score)/\(maxScore)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(color)
                .frame(width: 35, alignment: .trailing)
        }
        .frame(height: 16)
    }

    // MARK: - Cost Prediction

    @ViewBuilder
    private var rateLimitSection: some View {
        if let data = viewModel.rateLimitData {
            GlassCard {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(icon: "gauge.with.dots.needle.50percent", title: L10n.rateLimit, accentColor: Theme.cyan, helpText: L10n.helpRateLimit)

                    HStack(spacing: 12) {
                        rateLimitGauge(
                            label: L10n.fiveHourUsage,
                            percent: data.fiveHourPercent,
                            resetTime: UsageAPI.formatResetTime(data.fiveHourResetsAt),
                            alertLevel: viewModel.burnAlertLevel5h
                        )
                        rateLimitGauge(
                            label: L10n.sevenDayUsage,
                            percent: data.sevenDayPercent,
                            resetTime: UsageAPI.formatResetTime(data.sevenDayResetsAt),
                            alertLevel: viewModel.burnAlertLevel7d
                        )
                    }
                }
            }
        } else if viewModel.isTokenExpired {
            GlassCard {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(icon: "gauge.with.dots.needle.50percent", title: L10n.rateLimit, accentColor: Theme.cyan, helpText: L10n.helpRateLimit)
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.red)
                        Text(L10n.isChinese ? "Token 已过期，请在设置中重新获取" : "Token expired, please get a new one in Settings")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.red)
                    }
                }
            }
        }
    }

    private func rateLimitGauge(label: String, percent: Int, resetTime: String, alertLevel: BurnAlertLevel = .none) -> some View {
        let labelColor: Color = {
            switch alertLevel {
            case .critical: return Theme.red
            case .warning: return Color.orange
            case .info: return Theme.amber
            case .none: return Theme.textTertiary
            }
        }()

        return VStack(spacing: 6) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(labelColor)

            ZStack {
                // Background track
                Circle()
                    .stroke(Theme.border, lineWidth: 4)
                    .frame(width: 52, height: 52)

                // Progress arc
                Circle()
                    .trim(from: 0, to: CGFloat(percent) / 100)
                    .stroke(
                        percent >= 80 ? Theme.red : percent >= 50 ? Theme.amber : Theme.green,
                        style: StrokeStyle(lineWidth: 4, lineCap: .round)
                    )
                    .frame(width: 52, height: 52)
                    .rotationEffect(.degrees(-90))

                Text("\(percent)%")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(percent >= 80 ? Theme.red : Theme.textPrimary)
            }

            if !resetTime.isEmpty {
                Text(L10n.resetsAt + " " + resetTime)
                    .font(.system(size: 8))
                    .foregroundColor(Theme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func costPredictionSection(stats: SessionStats) -> some View {
        let activeDays = viewModel.dailyStats.filter { $0.cost > 0 }.count
        let cost = stats.estimatedCost
        let dailyAvg = activeDays > 0 ? cost / Double(activeDays) : 0
        let monthProjection = dailyAvg * 30

        return GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(icon: "chart.line.uptrend.xyaxis", title: L10n.costPrediction, accentColor: Theme.amber, helpText: L10n.helpCostPrediction)

                if activeDays > 0 && cost > 0 {
                    HStack(spacing: 16) {
                        VStack(spacing: 4) {
                            Text(L10n.dailyAvg)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(Theme.textTertiary)
                            Text(CostEstimator.formatCost(dailyAvg))
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundColor(Theme.amber)
                        }
                        .frame(maxWidth: .infinity)

                        Rectangle()
                            .fill(Theme.textTertiary.opacity(0.2))
                            .frame(width: 1, height: 30)

                        VStack(spacing: 4) {
                            Text(L10n.monthProjection)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(Theme.textTertiary)
                            Text(CostEstimator.formatCost(monthProjection))
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundColor(monthProjection > 1000 ? Theme.red : Theme.green)
                        }
                        .frame(maxWidth: .infinity)

                        Rectangle()
                            .fill(Theme.textTertiary.opacity(0.2))
                            .frame(width: 1, height: 30)

                        VStack(spacing: 4) {
                            Text(L10n.active)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(Theme.textTertiary)
                            Text("\(activeDays)" + (L10n.isChinese ? "天" : "d"))
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundColor(Theme.textPrimary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    Text(L10n.noData)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                }
            }
        }
    }

    // MARK: - Process Manager

    private var processSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionHeader(icon: "memorychip", title: L10n.processes, accentColor: Theme.cyan)
                    Spacer()
                    Button {
                        DispatchQueue.global().async {
                            let p = ProcessInfo2.scan()
                            DispatchQueue.main.async { processes = p }
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }

                if processes.isEmpty {
                    Text("—")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                } else {
                    let totalMB = processes.reduce(0.0) { $0 + $1.memoryMB }
                    Text(String(format: "%.0f MB / %d processes", totalMB, processes.count))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(Theme.textSecondary)

                    ForEach(processes) { proc in
                        HStack(spacing: 6) {
                            Text(proc.displayName)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(Theme.textPrimary)
                                .lineLimit(1)

                            Spacer()

                            Text(String(format: "%.0f MB", proc.memoryMB))
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundColor(Theme.amber)
                                .frame(width: 55, alignment: .trailing)

                            // Kill button (not for self)
                            if !proc.command.contains("CCStats") {
                                Button {
                                    ProcessInfo2.kill(pid: proc.pid)
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                        Task.detached { let p = ProcessInfo2.scan(); await MainActor.run { processes = p } }
                                    }
                                } label: {
                                    Image(systemName: "xmark.circle")
                                        .font(.system(size: 10))
                                        .foregroundColor(Theme.red.opacity(0.6))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .onAppear {
            // 延迟加载，不阻塞面板弹出
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                let p = ProcessInfo2.scan()
                DispatchQueue.main.async { processes = p }
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func sourceIcon(_ source: DataSource, size: CGFloat) -> some View {
        Image(systemName: source.icon)
            .font(.system(size: size * 0.75, weight: .semibold))
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(seconds)
        if totalSeconds < 60 {
            return "\(totalSeconds)s"
        } else if totalSeconds < 3600 {
            let m = totalSeconds / 60
            let s = totalSeconds % 60
            return s > 0 ? "\(m)m \(s)s" : "\(m)m"
        } else {
            let h = totalSeconds / 3600
            let m = (totalSeconds % 3600) / 60
            return m > 0 ? "\(h)h \(m)m" : "\(h)h"
        }
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000_000 {
            return String(format: "%.1fB", Double(count) / 1_000_000_000)
        } else if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }

    private func aggregateByLanguage(_ changes: [CodeChange]) -> [(language: String, additions: Int, deletions: Int)] {
        var dict: [String: (add: Int, del: Int)] = [:]
        for change in changes {
            let existing = dict[change.language] ?? (0, 0)
            dict[change.language] = (existing.add + change.additions, existing.del + change.deletions)
        }
        return dict.map { (language: $0.key, additions: $0.value.add, deletions: $0.value.del) }
    }

    // MARK: - Export

    private func exportJSON(stats: SessionStats) {
        var data: [String: Any] = [
            "sessions": stats.sessionCount,
            "instructions": stats.userInstructions,
            "total_duration_seconds": stats.totalDuration,
            "ai_processing_seconds": stats.aiProcessingTime,
            "user_active_seconds": stats.userActiveTime,
            "total_tokens": stats.totalTokens,
            "estimated_cost_usd": round(stats.estimatedCost * 100) / 100,
            "git_commits": stats.gitCommits,
            "git_additions": stats.gitAdditions,
            "git_deletions": stats.gitDeletions,
        ]
        // Tool calls
        data["tool_calls"] = stats.toolCalls
        // Token by model
        var tokenByModel: [String: [String: Any]] = [:]
        for (model, detail) in stats.tokenUsage {
            tokenByModel[model] = [
                "input": detail.inputTokens,
                "output": detail.outputTokens,
                "cache_read": detail.cacheReadInputTokens,
                "cache_creation": detail.cacheCreationInputTokens,
                "total": detail.totalTokens,
                "cost_usd": round(CostEstimator.estimateCostForModel(model, detail: detail) * 100) / 100,
            ]
        }
        data["token_by_model"] = tokenByModel

        if let jsonData = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]),
           let jsonStr = String(data: jsonData, encoding: .utf8) {
            saveToFile(content: jsonStr, ext: "json")
        }
    }

    private func exportCSV(stats: SessionStats) {
        var lines = ["metric,value"]
        lines.append("sessions,\(stats.sessionCount)")
        lines.append("instructions,\(stats.userInstructions)")
        lines.append("total_duration_seconds,\(Int(stats.totalDuration))")
        lines.append("ai_processing_seconds,\(Int(stats.aiProcessingTime))")
        lines.append("user_active_seconds,\(Int(stats.userActiveTime))")
        lines.append("total_tokens,\(stats.totalTokens)")
        lines.append("estimated_cost_usd,\(String(format: "%.2f", stats.estimatedCost))")
        lines.append("git_commits,\(stats.gitCommits)")
        lines.append("git_additions,\(stats.gitAdditions)")
        lines.append("git_deletions,\(stats.gitDeletions)")

        for (tool, count) in stats.toolCalls.sorted(by: { $0.value > $1.value }) {
            lines.append("tool_\(tool),\(count)")
        }
        for (model, detail) in stats.tokenUsage.sorted(by: { $0.value.totalTokens > $1.value.totalTokens }) {
            lines.append("token_\(model)_total,\(detail.totalTokens)")
            lines.append("token_\(model)_cost_usd,\(String(format: "%.2f", CostEstimator.estimateCostForModel(model, detail: detail)))")
        }

        saveToFile(content: lines.joined(separator: "\n"), ext: "csv")
    }

    private func saveToFile(content: String, ext: String) {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        let fileName = "cc-stats-export.\(ext)"
        let url = desktop.appendingPathComponent(fileName)
        try? content.write(to: url, atomically: true, encoding: .utf8)
        NSWorkspace.shared.open(url)

        withAnimation { toastMessage = L10n.exportedToDesktop }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { toastMessage = nil }
        }
    }
}

// MARK: - TimeFilter Extension

extension TimeFilter {
    var label: String { displayName }
}
