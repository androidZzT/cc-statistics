import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - DashboardView

struct DashboardView: View {
    @ObservedObject var viewModel: StatsViewModel
    @State private var toastMessage: String?

    var body: some View {
        ZStack {
        Group {
            if viewModel.showSettings {
                SettingsView(
                    isPresented: $viewModel.showSettings,
                    onLanguageChanged: { viewModel.languageVersion += 1 },
                    onThemeChanged: { viewModel.themeMode = $0 }
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
                .id(viewModel.languageVersion)
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

            // Full-view loading overlay
            ZStack {
                if viewModel.isLoading {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()

                    VStack(spacing: 16) {
                        TimelineView(.animation) { timeline in
                            Circle()
                                .trim(from: 0, to: 0.7)
                                .stroke(Theme.cyan, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                .frame(width: 40, height: 40)
                                .rotationEffect(.degrees(timeline.date.timeIntervalSince1970 * 200))
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
        .preferredColorScheme(resolvedColorScheme)
    }

    private var resolvedColorScheme: ColorScheme? {
        switch viewModel.themeMode {
        case "dark": return .dark
        case "light": return .light
        default: return nil  // follow system
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
                    let source: DataSource = tab == .claudeCode ? .claudeCode : .cursor
                    viewModel.selectSource(source)
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
                        trendChart
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
                accentColor: Theme.cyan
            )
            StatCard(
                icon: "text.bubble.fill",
                title: L10n.instructions,
                value: "\(stats.userInstructions)",
                accentColor: Theme.purple
            )
            StatCard(
                icon: "clock.fill",
                title: L10n.duration,
                value: formatDuration(stats.totalDuration),
                accentColor: Theme.green
            )
            StatCard(
                icon: "dollarsign.circle.fill",
                title: L10n.estimatedCost,
                value: CostEstimator.formatCost(stats.estimatedCost),
                accentColor: Theme.amber
            )
        }
    }

    // MARK: - Tool Calls Section

    private func toolCallsSection(stats: SessionStats) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(icon: "hammer.fill", title: L10n.toolCalls, accentColor: Theme.cyan)

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
                SectionHeader(icon: "chart.pie.fill", title: L10n.devTime, accentColor: Theme.green)

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
                    SectionHeader(icon: "chevron.left.forwardslash.chevron.right", title: L10n.codeChanges, accentColor: Theme.pink)
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
                SectionHeader(icon: "circle.hexagonpath.fill", title: L10n.tokenUsage, accentColor: Theme.amber)

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
                SectionHeader(icon: "chart.xyaxis.line", title: L10n.dailyTrend, accentColor: Theme.cyan)

                let data = viewModel.dailyStats.filter { $0.tokens > 0 || $0.sessions > 0 }
                if data.isEmpty {
                    Text(L10n.noData)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                        .padding(.vertical, 8)
                } else {
                    // Mini bar chart using SwiftUI shapes
                    let maxCost = data.map(\.cost).max() ?? 1
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(viewModel.dailyStats) { point in
                            VStack(spacing: 2) {
                                if point.cost > 0 {
                                    Text(CostEstimator.formatCost(point.cost))
                                        .font(.system(size: 7, weight: .medium, design: .monospaced))
                                        .foregroundColor(Theme.amber)
                                }
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(
                                        LinearGradient(
                                            colors: [Theme.cyan.opacity(0.8), Theme.purple.opacity(0.8)],
                                            startPoint: .bottom,
                                            endPoint: .top
                                        )
                                    )
                                    .frame(height: max(2, CGFloat(point.cost / maxCost) * 60))
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
