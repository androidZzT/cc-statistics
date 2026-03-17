import SwiftUI

// MARK: - DashboardView

struct DashboardView: View {
    @ObservedObject var viewModel: StatsViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Top toolbar
            toolbarSection

            // Tab switcher (hidden, code retained)
            // tabSwitcher

            if viewModel.activeTab == .claudeCode {
                claudeCodeContent
            } else {
                cursorContent
            }

            // Bottom bar
            footerSection
        }
        .frame(width: 480)
        .frame(maxHeight: 640)
        .background(Theme.background)
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
                    viewModel.activeTab = tab
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
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 14) {
                        headerCards(stats: stats)
                        developmentTimeSection(stats: stats)
                        codeChangesSection(stats: stats)
                        tokenUsageSection(stats: stats)
                        toolCallsSection(stats: stats)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 14)
                }
            } else {
                emptyState
            }
        }
    }

    // MARK: - Cursor Content

    private var cursorContent: some View {
        CursorStatsView(cursorStats: viewModel.cursorStats, isLoading: viewModel.isLoading)
    }

    // MARK: - Toolbar

    private var toolbarSection: some View {
        HStack(spacing: 10) {
            // Project selector
            Menu {
                Button {
                    viewModel.selectProject(nil)
                } label: {
                    HStack {
                        Text("所有项目")
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
                    Text(viewModel.selectedProject?.name ?? "所有项目")
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

            Spacer()

            // Time filter pills
            timeFilterPills
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
                title: "会话",
                value: "\(stats.sessionCount)",
                accentColor: Theme.cyan
            )
            StatCard(
                icon: "text.bubble.fill",
                title: "指令",
                value: "\(stats.userInstructions)",
                accentColor: Theme.purple
            )
            StatCard(
                icon: "clock.fill",
                title: "时长",
                value: formatDuration(stats.totalDuration),
                accentColor: Theme.green
            )
            StatCard(
                icon: "circlebadge.2.fill",
                title: "Token",
                value: formatTokens(stats.totalTokens),
                accentColor: Theme.amber
            )
        }
    }

    // MARK: - Tool Calls Section

    private func toolCallsSection(stats: SessionStats) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(icon: "hammer.fill", title: "工具调用", accentColor: Theme.cyan)

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

    // MARK: - Development Time Section

    private func developmentTimeSection(stats: SessionStats) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(icon: "chart.pie.fill", title: "开发时间", accentColor: Theme.green)

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
                        label: "AI 占比"
                    )

                    // Time breakdown
                    VStack(spacing: 8) {
                        TimeBreakdownRow(
                            icon: "clock.fill",
                            label: "总时间",
                            value: formatDuration(stats.totalDuration),
                            color: Theme.cyan
                        )
                        Divider()
                            .background(Theme.border)
                        TimeBreakdownRow(
                            icon: "cpu",
                            label: "AI 处理",
                            value: formatDuration(stats.aiProcessingTime),
                            color: Theme.purple
                        )
                        Divider()
                            .background(Theme.border)
                        TimeBreakdownRow(
                            icon: "person.fill",
                            label: "用户活跃",
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
                    SectionHeader(icon: "chevron.left.forwardslash.chevron.right", title: "代码变更", accentColor: Theme.pink)
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
                        Text("\(stats.gitCommits) 次提交")
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
                    Text("未检测到代码变更")
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
                SectionHeader(icon: "circle.hexagonpath.fill", title: "Token 用量", accentColor: Theme.amber)

                let tokenEntries = stats.tokenUsage.sorted(by: { $0.value.totalTokens > $1.value.totalTokens })

                ForEach(Array(tokenEntries.enumerated()), id: \.offset) { index, entry in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(entry.key)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(Theme.textPrimary)
                            Spacer()
                            Text(formatTokens(entry.value.totalTokens))
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(Theme.textSecondary)
                        }

                        TokenStackedBar(
                            segments: [
                                (label: "输入", value: entry.value.inputTokens, color: Theme.cyan),
                                (label: "输出", value: entry.value.outputTokens, color: Theme.purple),
                                (label: "缓存读", value: entry.value.cacheReadInputTokens, color: Theme.green),
                                (label: "缓存写", value: entry.value.cacheCreationInputTokens, color: Theme.amber),
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
                    TokenPill(label: "输入", count: stats.totalInputTokens, color: Theme.cyan)
                    TokenPill(label: "输出", count: stats.totalOutputTokens, color: Theme.purple)
                    TokenPill(label: "缓存", count: stats.totalCacheReadTokens + stats.totalCacheCreationTokens, color: Theme.green)
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
                    Text("对话")
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
                    Text("刷新")
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
            Text("暂无会话数据")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Text("启动 Claude Code 会话即可查看统计数据。")
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: - Helpers

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
        if count >= 1_000_000 {
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
}

// MARK: - TimeFilter Extension

extension TimeFilter {
    var label: String {
        switch self {
        case .today:  return "今天"
        case .week:   return "本周"
        case .month:  return "本月"
        case .all:    return "全部"
        }
    }
}
