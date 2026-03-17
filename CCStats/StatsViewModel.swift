import Foundation
import SwiftUI
import Combine

// MARK: - TimeFilter

enum TimeFilter: String, CaseIterable, Identifiable {
    case today
    case week
    case month
    case all

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .today: return "今天"
        case .week: return "本周"
        case .month: return "本月"
        case .all: return "所有时间"
        }
    }

    var startDate: Date? {
        let calendar = Calendar.current
        let now = Date()
        switch self {
        case .today:
            return calendar.startOfDay(for: now)
        case .week:
            return calendar.date(byAdding: .day, value: -7, to: now)
        case .month:
            return calendar.date(byAdding: .month, value: -1, to: now)
        case .all:
            return nil
        }
    }
}

// MARK: - StatsViewModel

@MainActor
final class StatsViewModel: ObservableObject {
    @Published var projects: [ProjectInfo] = []
    @Published var selectedProject: ProjectInfo?
    @Published var timeFilter: TimeFilter = .week
    @Published var stats: SessionStats?
    @Published var isLoading = false
    @Published var lastRefreshed: Date?
    @Published var recentSessions: [Session] = []
    @Published var showConversationPanel: Bool = false
    @Published var cursorStats: CursorStats?
    @Published var activeTab: StatsTab = .claudeCode

    enum StatsTab: String, CaseIterable {
        case claudeCode = "Claude Code"
        case cursor = "Cursor"
    }

    private var refreshTimer: Timer?

    init() {
        startAutoRefresh()
        Task {
            await performRefresh()
        }
    }

    deinit {
        refreshTimer?.invalidate()
    }

    // MARK: - Public Methods

    func refresh() {
        Task {
            await performRefresh()
        }
    }

    func performRefresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let currentFilter = timeFilter
        let currentProject = selectedProject

        let result: ([ProjectInfo], SessionStats, [Session]) = await Task.detached(priority: .userInitiated) {
            let parser = SessionParser()
            let loadedProjects = parser.findAllProjects()

            var sessions: [Session]
            if let project = currentProject {
                sessions = parser.parseSessions(forProject: project.path)
            } else {
                sessions = parser.parseAllSessions()
            }

            // Filter sessions by time range
            if let startDate = currentFilter.startDate {
                sessions = sessions.filter { session in
                    session.messages.contains { message in
                        if let ts = message.timestamp {
                            return ts >= startDate
                        }
                        return false
                    }
                }
            }

            let stats = SessionAnalyzer.analyze(sessions: sessions)
            let recentSessions = sessions.sorted(by: { ($0.startTime ?? .distantPast) > ($1.startTime ?? .distantPast) }).prefix(20).map { $0 }
            return (loadedProjects, stats, recentSessions)
        }.value

        self.projects = result.0
        self.stats = result.1
        self.recentSessions = result.2

        // Also parse Cursor stats
        let cursorSince = currentFilter.startDate
        let cursorResult: CursorStats = await Task.detached(priority: .userInitiated) {
            CursorParser.parse(since: cursorSince)
        }.value
        self.cursorStats = cursorResult

        self.lastRefreshed = Date()
    }

    func selectProject(_ project: ProjectInfo?) {
        selectedProject = project
        Task {
            await performRefresh()
        }
    }

    func setTimeFilter(_ filter: TimeFilter) {
        timeFilter = filter
        Task {
            await performRefresh()
        }
    }

    func toggleConversationPanel() {
        showConversationPanel.toggle()
    }

    // MARK: - Private Methods

    private func startAutoRefresh() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.refresh()
            }
        }
    }
}
