import SwiftUI

// MARK: - CursorStatsView

struct CursorStatsView: View {
    let cursorStats: CursorStats?
    let isLoading: Bool

    var body: some View {
        if isLoading && cursorStats == nil {
            loadingState
        } else if let stats = cursorStats {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 14) {
                    statsCardsRow(stats: stats)
                    aiCodeTrackingSection(stats: stats)
                    sessionModesSection(stats: stats)
                    modelsUsageSection(stats: stats)
                    recentSessionsSection(stats: stats)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 14)
            }
        } else {
            emptyState
        }
    }

    // MARK: - Stats Cards Row

    private func statsCardsRow(stats: CursorStats) -> some View {
        HStack(spacing: 8) {
            StatCard(
                icon: "terminal.fill",
                title: "会话",
                value: "\(stats.totalSessions)",
                accentColor: Theme.teal
            )
            StatCard(
                icon: "text.bubble.fill",
                title: "消息",
                value: formatCount(stats.totalMessages),
                accentColor: Theme.blue
            )
            StatCard(
                icon: "plus.forwardslash.minus",
                title: "新增",
                value: "+\(formatCount(stats.totalLinesAdded))",
                accentColor: Theme.green
            )
            StatCard(
                icon: "minus.circle.fill",
                title: "删除",
                value: "-\(formatCount(stats.totalLinesRemoved))",
                accentColor: Theme.red
            )
        }
    }

    // MARK: - AI Code Tracking Section

    private func aiCodeTrackingSection(stats: CursorStats) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(icon: "wand.and.stars", title: "AI 代码追踪", accentColor: Theme.cyan)

                if stats.totalSuggested == 0 {
                    Text("暂无 AI 代码数据")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                        .padding(.vertical, 4)
                } else {
                    // Main metrics row
                    HStack(spacing: 12) {
                        // Acceptance rate ring
                        ActivityRing(
                            progress: stats.overallAcceptanceRate,
                            lineWidth: 7,
                            size: 80,
                            gradientColors: [Theme.green, Theme.teal],
                            label: "采纳率"
                        )

                        // Metrics
                        VStack(spacing: 8) {
                            aiMetricRow(
                                icon: "sparkles",
                                label: "AI 生成行数",
                                value: "\(formatCount(stats.totalSuggested))",
                                color: Theme.cyan
                            )
                            Divider().background(Theme.border)
                            aiMetricRow(
                                icon: "checkmark.circle.fill",
                                label: "采纳行数",
                                value: "\(formatCount(stats.totalAccepted))",
                                color: Theme.green
                            )
                            Divider().background(Theme.border)
                            aiMetricRow(
                                icon: "arrow.up.right",
                                label: "增量行数",
                                value: "\(formatCount(stats.totalAccepted))",
                                color: Theme.amber
                            )
                        }
                        .frame(maxWidth: .infinity)
                    }

                    // Tab vs Composer breakdown
                    VStack(spacing: 6) {
                        HStack(spacing: 8) {
                            sourceBreakdown(
                                label: "Tab 补全",
                                suggested: stats.totalTabSuggested,
                                accepted: stats.totalTabAccepted,
                                rate: stats.tabAcceptanceRate,
                                color: Theme.blue
                            )
                            sourceBreakdown(
                                label: "Composer",
                                suggested: stats.totalComposerSuggested,
                                accepted: stats.totalComposerAccepted,
                                rate: stats.composerAcceptanceRate,
                                color: Theme.purple
                            )
                        }
                    }

                    // Stacked bar for tab vs composer
                    TokenStackedBar(
                        segments: [
                            (label: "Tab 采纳", value: stats.totalTabAccepted, color: Theme.blue),
                            (label: "Composer 采纳", value: stats.totalComposerAccepted, color: Theme.purple),
                        ],
                        height: 10
                    )

                    // Daily trend
                    if stats.dailyCodeStats.count > 1 {
                        dailyTrendSection(stats: stats)
                    }
                }
            }
        }
    }

    private func aiMetricRow(icon: String, label: String, value: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(color)
                .frame(width: 16)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Theme.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.textPrimary)
        }
    }

    private func sourceBreakdown(label: String, suggested: Int, accepted: Int, rate: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                    .shadow(color: color.opacity(0.5), radius: 3, x: 0, y: 0)
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
            }
            HStack(spacing: 6) {
                Text("生成 \(formatCount(suggested))")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(Theme.textSecondary)
                Text("采纳 \(formatCount(accepted))")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(Theme.green)
            }
            Text(String(format: "采纳率 %.1f%%", rate * 100))
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(color)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(color.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(color.opacity(0.15), lineWidth: 0.5)
                )
        )
    }

    private func dailyTrendSection(stats: CursorStats) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("每日趋势")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(Theme.textSecondary)
                .textCase(.uppercase)
                .tracking(0.5)

            let days = Array(stats.dailyCodeStats.prefix(7).reversed())
            let maxVal = days.map { $0.totalSuggested }.max() ?? 1

            VStack(spacing: 3) {
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                    HStack(spacing: 6) {
                        Text(formatDayLabel(day.date))
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundColor(Theme.textTertiary)
                            .frame(width: 42, alignment: .leading)

                        GeometryReader { geometry in
                            let suggestedFrac = CGFloat(day.totalSuggested) / CGFloat(max(maxVal, 1))
                            let acceptedFrac = CGFloat(day.totalAccepted) / CGFloat(max(maxVal, 1))

                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .fill(Color.white.opacity(0.04))
                                    .frame(height: 8)
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .fill(Theme.cyan.opacity(0.3))
                                    .frame(width: max(geometry.size.width * suggestedFrac, 2), height: 8)
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .fill(Theme.green)
                                    .frame(width: max(geometry.size.width * acceptedFrac, 2), height: 8)
                            }
                        }
                        .frame(height: 8)

                        Text(String(format: "%.0f%%", day.acceptanceRate * 100))
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundColor(Theme.green)
                            .frame(width: 32, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func formatDayLabel(_ dateStr: String) -> String {
        // "2026-02-09" -> "02/09"
        let parts = dateStr.split(separator: "-")
        guard parts.count == 3 else { return dateStr }
        return "\(parts[1])/\(parts[2])"
    }

    // MARK: - Session Modes Section

    private func sessionModesSection(stats: CursorStats) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(icon: "rectangle.3.group.fill", title: "会话模式", accentColor: Theme.purple)

                HStack(spacing: 8) {
                    modeBadge(label: "Agent", count: stats.agentSessions, color: Theme.purple)
                    modeBadge(label: "Chat", count: stats.chatSessions, color: Theme.cyan)
                    modeBadge(label: "Edit", count: stats.editSessions, color: Theme.amber)
                }

                let total = stats.agentSessions + stats.chatSessions + stats.editSessions
                if total > 0 {
                    TokenStackedBar(
                        segments: [
                            (label: "Agent", value: stats.agentSessions, color: Theme.purple),
                            (label: "Chat", value: stats.chatSessions, color: Theme.cyan),
                            (label: "Edit", value: stats.editSessions, color: Theme.amber),
                        ],
                        height: 10
                    )
                }
            }
        }
    }

    private func modeBadge(label: String, count: Int, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .shadow(color: color.opacity(0.5), radius: 3, x: 0, y: 0)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Theme.textSecondary)
            Text("\(count)")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.textPrimary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(color.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(color.opacity(0.15), lineWidth: 0.5)
                )
        )
    }

    // MARK: - Models Usage Section

    private func modelsUsageSection(stats: CursorStats) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(icon: "cpu.fill", title: "模型使用", accentColor: Theme.indigo)

                let sortedModels = stats.modelUsage
                    .sorted(by: { $0.value > $1.value })
                    .prefix(10)
                let maxCount = sortedModels.first?.value ?? 1

                if sortedModels.isEmpty {
                    Text("暂无模型使用数据")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                        .padding(.vertical, 4)
                } else {
                    VStack(spacing: 4) {
                        ForEach(Array(sortedModels.enumerated()), id: \.offset) { index, model in
                            BarChartRow(
                                label: model.key,
                                value: model.value,
                                maxValue: maxCount,
                                color: Theme.barGradientColors[index % Theme.barGradientColors.count],
                                rank: index + 1
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - Recent Sessions Section

    private func recentSessionsSection(stats: CursorStats) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(icon: "clock.fill", title: "最近会话", accentColor: Theme.teal)

                let sessions = Array(stats.recentSessions.prefix(10))

                if sessions.isEmpty {
                    Text("暂无最近会话")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                        .padding(.vertical, 4)
                } else {
                    VStack(spacing: 2) {
                        ForEach(Array(sessions.enumerated()), id: \.offset) { index, session in
                            sessionRow(session: session)

                            if index < sessions.count - 1 {
                                Divider()
                                    .background(Theme.border)
                            }
                        }
                    }
                }
            }
        }
    }

    private func sessionRow(session: (id: String, date: Date, model: String, mode: String, linesAdded: Int, linesRemoved: Int)) -> some View {
        HStack(spacing: 8) {
            Text(formatSessionDate(session.date))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(Theme.textSecondary)
                .frame(width: 70, alignment: .leading)

            Text(truncateModel(session.model))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(Theme.textPrimary)
                .frame(width: 100, alignment: .leading)
                .lineLimit(1)

            Text(session.mode.capitalized)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(modeColor(session.mode))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(modeColor(session.mode).opacity(0.12))
                )

            Spacer()

            HStack(spacing: 6) {
                Text("+\(session.linesAdded)")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(Theme.green)
                Text("-\(session.linesRemoved)")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(Theme.red)
            }
        }
        .padding(.vertical, 4)
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
            Image(systemName: "cursorarrow.rays")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Theme.teal, Theme.blue],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Text("暂无 Cursor 数据")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Text("打开 Cursor IDE 开始追踪使用统计。")
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: - Helpers

    private func formatCount(_ n: Int) -> String {
        if n >= 1_000_000 {
            return String(format: "%.1fM", Double(n) / 1_000_000)
        } else if n >= 1_000 {
            return String(format: "%.1fK", Double(n) / 1_000)
        }
        return "\(n)"
    }

    private func formatSessionDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "HH:mm"
        } else {
            formatter.dateFormat = "MM/dd HH:mm"
        }
        return formatter.string(from: date)
    }

    private func truncateModel(_ model: String) -> String {
        if model.count > 16 {
            return String(model.prefix(14)) + ".."
        }
        return model
    }

    private func modeColor(_ mode: String) -> Color {
        switch mode.lowercased() {
        case "agent":  return Theme.purple
        case "chat":   return Theme.cyan
        case "edit":   return Theme.amber
        default:       return Theme.textSecondary
        }
    }
}
