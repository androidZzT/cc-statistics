import AppKit
import Foundation
import SwiftUI

// MARK: - Island Overlay

private struct NotchMetrics: Equatable {
    let width: CGFloat
    let height: CGFloat
}

private struct IslandLayout: Equatable {
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    var islandWidth: CGFloat
    var islandHeight: CGFloat
    var compact: Bool

    static let zero = IslandLayout(
        notchWidth: 190,
        notchHeight: 38,
        islandWidth: 260,
        islandHeight: 38,
        compact: true
    )
}

private enum IslandVisualState: Equatable {
    case hidden
    case running
    case waitingApproval
    case completed
    case failed
}

private enum IslandAvatarMotion: String, Equatable {
    case idle
    case thinking
    case typing
    case building
    case juggling
    case conducting
    case notification
    case error
    case happy
    case sweeping
    case carrying
    case sleeping
}

private struct IslandDisplayPayload: Equatable {
    var state: IslandVisualState
    var title: String
    var subtitle: String
    var toolName: String
    var actionText: String
    var approvalId: String?
    var taskId: String?
    var metaText: String
    var motion: IslandAvatarMotion = .idle
}

@MainActor
private final class IslandOverlayModel: ObservableObject {
    @Published var payload: IslandDisplayPayload = .init(
        state: .hidden,
        title: "",
        subtitle: "",
        toolName: "",
        actionText: "",
        approvalId: nil,
        taskId: nil,
        metaText: ""
    )
    @Published var layout: IslandLayout = .zero
    @Published var isResolving: Bool = false
    var onApprove: (() -> Void)?
    var onReject: (() -> Void)?
    var onOpenDashboard: (() -> Void)?
    var onOpenChat: (() -> Void)?
    var onOpenTerminal: (() -> Void)?
    var onExpandApproval: (() -> Void)?
    var onExpandRunning: (() -> Void)?
    var onDismiss: (() -> Void)?
}

private final class IslandOverlayPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        level = .mainMenu + 3
        collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    var hitTestRectProvider: () -> CGRect = { .zero }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard hitTestRectProvider().contains(point) else {
            return nil
        }
        return super.hitTest(point)
    }
}

private final class LocalBridgeApprovalClient {
    static let shared = LocalBridgeApprovalClient()

    private init() {}

    func resolve(approvalId: String, approved: Bool, completion: @escaping (Bool) -> Void) {
        guard let url = approvalURL(for: approvalId) else {
            completion(false)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "approved": approved,
            "resolver": "macos_island",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            completion(false)
            return
        }
        request.httpBody = body

        URLSession.shared.dataTask(with: request) { _, response, _ in
            guard let http = response as? HTTPURLResponse else {
                completion(false)
                return
            }
            completion((200...299).contains(http.statusCode))
        }.resume()
    }

    private func approvalURL(for approvalId: String) -> URL? {
        guard let encoded = approvalId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }
        let base = bridgeBaseURL()
        return URL(string: "/v1/approvals/\(encoded):resolve", relativeTo: base)
    }

    private func bridgeBaseURL() -> URL {
        let env = ProcessInfo.processInfo.environment["CC_STATS_BRIDGE_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaults = UserDefaults.standard.string(forKey: "cc_stats_bridge_url")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = (env?.isEmpty == false ? env : defaults) ?? "http://127.0.0.1:8765"
        return URL(string: raw) ?? URL(string: "http://127.0.0.1:8765")!
    }
}

@MainActor
final class IslandOverlayController {
    private let model = IslandOverlayModel()
    private var panel: IslandOverlayPanel?
    private var hostingView: PassThroughHostingView<IslandCapsuleView>?
    private var feedbackHideTask: DispatchWorkItem?
    private var globalOutsideClickMonitor: Any?
    private var localOutsideClickMonitor: Any?
    private var isApprovalCollapsed: Bool = false
    private var isRunningExpanded: Bool = false
    private var outsideClickArmedAt: Date?
    private var visibilityRevision: Int = 0
    private var debugModeEnabled: Bool = false
    private var latestSnapshot: SessionActivitySnapshot?
    private var latestLiveTask: BridgeLiveTaskSnapshot?
    private var dismissedTerminalTaskId: String?
    private let overlayHeight: CGFloat = 260
    private let outsideClickArmDelay: TimeInterval = 0.45
    var onOpenDashboard: (() -> Void)?
    var onOpenChat: (() -> Void)?
    var onOpenTerminal: (() -> Void)?

    func setDebugMode(_ enabled: Bool) {
        guard debugModeEnabled != enabled else { return }
        debugModeEnabled = enabled
        let snapshot = latestSnapshot ?? SessionActivitySnapshot(
            state: .idle,
            event: "",
            timestamp: nil,
            bridgeEnabled: false,
            approvalId: nil,
            toolName: nil,
            action: nil
        )
        let payload = effectivePayload(from: snapshot, liveTask: latestLiveTask)
        model.payload = payload
        render(payload)
    }

    func update(activitySnapshot snapshot: SessionActivitySnapshot, liveTask: BridgeLiveTaskSnapshot?) {
        latestSnapshot = snapshot
        latestLiveTask = liveTask
        feedbackHideTask?.cancel()
        feedbackHideTask = nil

        if let liveTask, liveTask.status == .running || liveTask.status == .waitingApproval {
            dismissedTerminalTaskId = nil
        }
        let payload = effectivePayload(from: snapshot, liveTask: liveTask)
        let previousPayload = model.payload
        let shouldResetCollapsedApproval =
            payload.state != .waitingApproval ||
            payload.approvalId != previousPayload.approvalId ||
            payload.toolName != previousPayload.toolName ||
            payload.actionText != previousPayload.actionText
        if shouldResetCollapsedApproval {
            isApprovalCollapsed = false
        }
        let shouldResetExpandedRunning =
            payload.state == .hidden ||
            (payload.taskId != previousPayload.taskId && payload.taskId != nil)
        if shouldResetExpandedRunning {
            isRunningExpanded = false
        }

        let changed = payload != previousPayload
        syncModelActions()
        let desiredCompact = wantsCompactLayout(for: payload)
        let layoutNeedsSync = model.layout.compact != desiredCompact
        let visibilityNeedsSync = (payload.state != .hidden) != (panel?.isVisible == true)
        let shouldFreezeDuringHide =
            payload.state == .hidden &&
            previousPayload.state != .hidden &&
            panel?.isVisible == true

        if shouldFreezeDuringHide {
            hide(animated: true, finalPayload: payload)
            return
        }

        model.payload = payload
        if changed || layoutNeedsSync || visibilityNeedsSync {
            render(payload)
        } else {
            syncMouseInteraction(with: payload)
        }
    }

    private func syncModelActions() {
        model.onApprove = { [weak self] in self?.resolveApproval(approved: true) }
        model.onReject = { [weak self] in self?.resolveApproval(approved: false) }
        model.onOpenDashboard = onOpenDashboard
        model.onOpenChat = onOpenChat
        model.onOpenTerminal = onOpenTerminal
        model.onExpandApproval = { [weak self] in self?.expandApprovalPanel() }
        model.onExpandRunning = { [weak self] in self?.expandRunningPanel() }
        model.onDismiss = { [weak self] in self?.dismissCurrentFeedback() }
    }

    private func render(_ payload: IslandDisplayPayload) {
        switch payload.state {
        case .hidden:
            hide(animated: true, finalPayload: payload)
        case .running, .waitingApproval, .completed, .failed:
            visibilityRevision &+= 1
            guard let screen = targetScreen() else { return }
            model.layout = islandLayout(for: payload, on: screen)
            showIfNeeded(on: screen)
            syncMouseInteraction(with: payload)
            applyPanelFrame(on: screen, animated: true)
            updateOutsideClickMonitoring(with: payload)
        }
    }

    private func resolveApproval(approved: Bool) {
        guard let approvalId = model.payload.approvalId, !approvalId.isEmpty else { return }
        guard !model.isResolving else { return }

        model.isResolving = true
        syncMouseInteraction(with: model.payload)

        LocalBridgeApprovalClient.shared.resolve(approvalId: approvalId, approved: approved) { [weak self] ok in
            DispatchQueue.main.async {
                guard let self else { return }
                self.model.isResolving = false
                if ok {
                    self.showDecisionFeedback(approved: approved)
                } else {
                    self.syncMouseInteraction(with: self.model.payload)
                }
            }
        }
    }

    private func showDecisionFeedback(approved: Bool) {
        isApprovalCollapsed = false
        let currentTaskId = model.payload.taskId
        let feedback = IslandDisplayPayload(
            state: approved ? .running : .failed,
            title: approved ? "Decision sent" : "Approval Denied",
            subtitle: approved ? "Approved from island" : "Rejected from island",
            toolName: "Claude",
            actionText: approved ? "Approved from island" : "The requested action was denied from the island.",
            approvalId: nil,
            taskId: currentTaskId,
            metaText: "",
            motion: approved ? .typing : .error
        )
        model.payload = feedback
        render(feedback)

        guard approved else { return }
        let task = DispatchWorkItem { [weak self] in
            self?.hide(animated: true)
        }
        feedbackHideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: task)
    }

    private func dismissCurrentFeedback() {
        if model.payload.state == .completed || model.payload.state == .failed {
            dismissedTerminalTaskId = model.payload.taskId
        }
        hide(animated: true)
    }

    private func showIfNeeded(on screen: NSScreen) {
        if panel == nil {
            let frame = overlayFrame(on: screen)
            let newPanel = IslandOverlayPanel(contentRect: frame)

            let host = PassThroughHostingView(rootView: IslandCapsuleView(model: model))
            host.translatesAutoresizingMaskIntoConstraints = false

            let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
            container.wantsLayer = true
            container.layer?.backgroundColor = NSColor.clear.cgColor
            container.addSubview(host)
            NSLayoutConstraint.activate([
                host.topAnchor.constraint(equalTo: container.topAnchor),
                host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])

            newPanel.contentView = container
            panel = newPanel
            hostingView = host
            host.hitTestRectProvider = { [weak newPanel] in
                guard let panel = newPanel else { return .zero }
                return panel.contentView?.bounds ?? .zero
            }
        }

        guard let panel else { return }
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        } else if panel.alphaValue < 0.999 {
            panel.animator().alphaValue = 1
        }
    }

    private func hide(animated: Bool, finalPayload: IslandDisplayPayload? = nil) {
        guard let panel, panel.isVisible else {
            if let finalPayload {
                model.payload = finalPayload
            }
            return
        }
        removeOutsideClickMonitors()
        panel.ignoresMouseEvents = true
        visibilityRevision &+= 1
        let revisionAtHide = visibilityRevision
        let close = {
            panel.orderOut(nil)
            panel.alphaValue = 1
            if let finalPayload {
                self.model.payload = finalPayload
            }
        }
        if animated {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 0
            }, completionHandler: {
                Task { @MainActor in
                    guard revisionAtHide == self.visibilityRevision else {
                        panel.alphaValue = 1
                        return
                    }
                    close()
                }
            })
        } else {
            close()
        }
    }

    private func applyPanelFrame(on screen: NSScreen, animated: Bool) {
        guard let panel else { return }
        let frame = overlayFrame(on: screen)
        guard panel.frame != frame else { return }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    private func overlayFrame(on screen: NSScreen) -> NSRect {
        let width = model.layout.islandWidth
        let height = model.layout.islandHeight
        return NSRect(
            x: round(screen.frame.midX - width / 2),
            y: round(screen.frame.maxY - height),
            width: width,
            height: height
        )
    }

    private func targetScreen() -> NSScreen? {
        let mousePoint = NSEvent.mouseLocation
        if let underMouse = NSScreen.screens.first(where: { $0.frame.contains(mousePoint) }) {
            return underMouse
        }
        if let builtin = NSScreen.screens.first(where: { $0.cc_isBuiltinDisplay }) {
            return builtin
        }
        if let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return notched
        }
        if let main = NSScreen.main {
            return main
        }
        return NSScreen.screens.first
    }

    private func islandLayout(for payload: IslandDisplayPayload, on screen: NSScreen) -> IslandLayout {
        let notch = notchMetrics(for: screen)
        let compactExpansionWidth = 2 * max(0, notch.height - 12) + 20
        let compactApprovalIndicatorWidth: CGFloat = 0
        let compactWidth = min(
            notch.width + compactExpansionWidth + compactApprovalIndicatorWidth,
            screen.frame.width - 48
        )
        let compactHeight = notch.height

        let expandedWidth = min(max(screen.frame.width * 0.4, 460), 480)
        let expandedHeight = min(max(notch.height + 150, 208), overlayHeight - 12)

        switch payload.state {
        case .running:
            if !wantsCompactLayout(for: payload) {
                return IslandLayout(
                    notchWidth: notch.width,
                    notchHeight: notch.height,
                    islandWidth: expandedWidth,
                    islandHeight: expandedHeight,
                    compact: false
                )
            }
            return IslandLayout(
                notchWidth: notch.width,
                notchHeight: notch.height,
                islandWidth: compactWidth,
                islandHeight: compactHeight,
                compact: true
            )
        case .completed, .failed:
            return IslandLayout(
                notchWidth: notch.width,
                notchHeight: notch.height,
                islandWidth: expandedWidth,
                islandHeight: expandedHeight,
                compact: false
            )
        case .waitingApproval:
            if wantsCompactLayout(for: payload) {
                return IslandLayout(
                    notchWidth: notch.width,
                    notchHeight: notch.height,
                    islandWidth: compactWidth,
                    islandHeight: compactHeight,
                    compact: true
                )
            }
            return IslandLayout(
                notchWidth: notch.width,
                notchHeight: notch.height,
                islandWidth: expandedWidth,
                islandHeight: expandedHeight,
                compact: false
            )
        case .hidden:
            return IslandLayout(
                notchWidth: notch.width,
                notchHeight: notch.height,
                islandWidth: compactWidth,
                islandHeight: compactHeight,
                compact: true
            )
        }
    }

    private func notchMetrics(for screen: NSScreen) -> NotchMetrics {
        guard screen.safeAreaInsets.top > 0 else {
            return NotchMetrics(width: 224, height: 38)
        }

        let notchHeight = screen.safeAreaInsets.top
        if #available(macOS 12.0, *),
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea,
           left.width > 0,
           right.width > 0 {
            let computed = screen.frame.width - left.width - right.width + 4
            if computed > 0 {
                return NotchMetrics(width: computed, height: notchHeight)
            }
        }
        return NotchMetrics(width: 180, height: notchHeight)
    }

    private func syncMouseInteraction(with payload: IslandDisplayPayload) {
        let isInteractive = payload.state != .hidden
        panel?.ignoresMouseEvents = !isInteractive
    }

    private func updateOutsideClickMonitoring(with payload: IslandDisplayPayload) {
        let shouldMonitor = payload.state != .hidden && !model.layout.compact && panel?.isVisible == true
        if shouldMonitor {
            installOutsideClickMonitorsIfNeeded()
            if outsideClickArmedAt == nil {
                outsideClickArmedAt = Date().addingTimeInterval(outsideClickArmDelay)
            }
        } else {
            removeOutsideClickMonitors()
        }
    }

    private func installOutsideClickMonitorsIfNeeded() {
        if globalOutsideClickMonitor == nil {
            globalOutsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.handleOutsideClick(at: NSEvent.mouseLocation)
                }
            }
        }

        if localOutsideClickMonitor == nil {
            localOutsideClickMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] event in
                self?.handleOutsideClick(at: Self.screenPoint(for: event))
                return event
            }
        }
    }

    private func removeOutsideClickMonitors() {
        if let globalOutsideClickMonitor {
            NSEvent.removeMonitor(globalOutsideClickMonitor)
            self.globalOutsideClickMonitor = nil
        }
        if let localOutsideClickMonitor {
            NSEvent.removeMonitor(localOutsideClickMonitor)
            self.localOutsideClickMonitor = nil
        }
        outsideClickArmedAt = nil
    }

    private func handleOutsideClick(at screenPoint: NSPoint) {
        guard model.payload.state != .hidden else { return }
        guard let panel, panel.isVisible else { return }
        if let armedAt = outsideClickArmedAt, Date() < armedAt {
            return
        }
        guard !panel.frame.contains(screenPoint) else { return }
        switch model.payload.state {
        case .waitingApproval:
            collapseApprovalPanel()
        case .running:
            collapseRunningPanel()
        case .completed, .failed:
            dismissCurrentFeedback()
        case .hidden:
            break
        }
    }

    private static func screenPoint(for event: NSEvent) -> NSPoint {
        if let window = event.window {
            return window.convertPoint(toScreen: event.locationInWindow)
        }
        return NSEvent.mouseLocation
    }

    private func wantsCompactLayout(for payload: IslandDisplayPayload) -> Bool {
        switch payload.state {
        case .hidden:
            return true
        case .running:
            return !isRunningExpanded
        case .completed, .failed:
            return false
        case .waitingApproval:
            return isApprovalCollapsed
        }
    }

    private func collapseApprovalPanel() {
        guard model.payload.state == .waitingApproval else { return }
        guard !isApprovalCollapsed else { return }
        isApprovalCollapsed = true
        outsideClickArmedAt = nil
        render(model.payload)
    }

    private func collapseRunningPanel() {
        guard model.payload.state == .running else { return }
        guard isRunningExpanded else { return }
        isRunningExpanded = false
        outsideClickArmedAt = nil
        render(model.payload)
    }

    private func expandApprovalPanel() {
        guard model.payload.state == .waitingApproval else { return }
        guard isApprovalCollapsed else { return }
        isApprovalCollapsed = false
        outsideClickArmedAt = Date().addingTimeInterval(outsideClickArmDelay)
        render(model.payload)
    }

    private func expandRunningPanel() {
        guard model.payload.state == .running else { return }
        guard !isRunningExpanded else { return }
        isRunningExpanded = true
        outsideClickArmedAt = Date().addingTimeInterval(outsideClickArmDelay)
        render(model.payload)
    }

    private func mapPayload(from snapshot: SessionActivitySnapshot, liveTask: BridgeLiveTaskSnapshot?) -> IslandDisplayPayload {
        if let liveTask, liveTask.status == .completed || liveTask.status == .failed || liveTask.status == .canceled {
            if dismissedTerminalTaskId == liveTask.taskId {
                return IslandDisplayPayload(state: .hidden, title: "", subtitle: "", toolName: "", actionText: "", approvalId: nil, taskId: nil, metaText: "")
            }
            return payload(from: liveTask)
        }

        switch snapshot.state {
        case .waitingApproval:
            if let liveTask, liveTask.status == .waitingApproval, liveTask.approvalId?.isEmpty == false {
                return payload(from: liveTask)
            }
            let tool = (snapshot.toolName?.isEmpty == false ? snapshot.toolName! : "Tool")
            let baseAction = sanitizedSubtitle(snapshot.action)
            let action = baseAction
            return IslandDisplayPayload(
                state: .waitingApproval,
                title: "Permission Request",
                subtitle: "Review this action before Claude continues.",
                toolName: tool,
                actionText: action.isEmpty ? "Action needs your confirmation" : action,
                approvalId: snapshot.approvalId,
                taskId: liveTask?.taskId,
                metaText: "",
                motion: .notification
            )
        case .active:
            if let liveTask, liveTask.status == .running || liveTask.status == .waitingApproval {
                return payload(from: liveTask, overridingMotionWith: snapshot)
            }
            return IslandDisplayPayload(
                state: .running,
                title: "Claude is coding",
                subtitle: "Active task in progress",
                toolName: "Claude",
                actionText: sanitizedSubtitle(snapshot.action),
                approvalId: nil,
                taskId: nil,
                metaText: "",
                motion: avatarMotion(from: snapshot)
            )
        case .idle, .sleeping:
            if let liveTask, liveTask.status == .running || liveTask.status == .waitingApproval {
                return payload(from: liveTask)
            }
            return IslandDisplayPayload(state: .hidden, title: "", subtitle: "", toolName: "", actionText: "", approvalId: nil, taskId: nil, metaText: "")
        }
    }

    private func effectivePayload(from snapshot: SessionActivitySnapshot, liveTask: BridgeLiveTaskSnapshot?) -> IslandDisplayPayload {
        let mapped = mapPayload(from: snapshot, liveTask: liveTask)
        guard debugModeEnabled else { return mapped }
        if mapped.state != .hidden { return mapped }
        return IslandDisplayPayload(
            state: .waitingApproval,
            title: "Permission Request",
            subtitle: "Debug preview pinned to the notch",
            toolName: "Preview",
            actionText: "Adjusting island spacing, sizing, and notch alignment",
            approvalId: nil,
            taskId: "debug-preview",
            metaText: "Plan · 14s · 32K in · $0.12",
            motion: .notification
        )
    }

    private func payload(from task: BridgeLiveTaskSnapshot) -> IslandDisplayPayload {
        if task.status == .waitingApproval {
            let action = sanitizedSubtitle(task.action ?? task.summary)
            let reason = sanitizedSubtitle(task.reason)
            return IslandDisplayPayload(
                state: .waitingApproval,
                title: "Permission Request",
                subtitle: reason.isEmpty ? "Review this action before Claude continues." : reason,
                toolName: task.toolName?.isEmpty == false ? task.toolName! : "Tool",
                actionText: action.isEmpty ? "Action needs your confirmation" : action,
                approvalId: task.approvalId,
                taskId: task.taskId,
                metaText: task.risk?.isEmpty == false ? "Risk: \(task.risk!.uppercased())" : liveMetaText(for: task),
                motion: .notification
            )
        }

        if task.status == .completed || task.status == .failed || task.status == .canceled {
            let denied = task.phase == "approval_denied"
                || task.errorMessage.localizedCaseInsensitiveContains("approval rejected")
                || task.summary.localizedCaseInsensitiveContains("approval rejected")
            let failed = task.status == .failed
            let canceled = task.status == .canceled
            let summary = sanitizedSubtitle(task.errorMessage.isEmpty ? task.summary : task.errorMessage)
            return IslandDisplayPayload(
                state: failed || canceled ? .failed : .completed,
                title: terminalTitle(failed: failed, canceled: canceled, denied: denied),
                subtitle: liveSubtitle(for: task),
                toolName: liveModelLabel(task.model),
                actionText: summary.isEmpty ? terminalFallbackMessage(failed: failed, canceled: canceled, denied: denied) : summary,
                approvalId: nil,
                taskId: task.taskId,
                metaText: liveMetaText(for: task),
                motion: failed || canceled ? .error : .happy
            )
        }

        let title = sanitizedTitle(task.title.isEmpty ? livePhaseTitle(task.phase) : task.title)
        let summary = sanitizedSubtitle(task.summary.isEmpty ? task.repo : task.summary)
        return IslandDisplayPayload(
            state: .running,
            title: title,
            subtitle: liveSubtitle(for: task),
            toolName: liveModelLabel(task.model),
            actionText: summary.isEmpty ? "Live task is running." : summary,
            approvalId: nil,
            taskId: task.taskId,
            metaText: liveMetaText(for: task),
            motion: avatarMotion(from: task)
        )
    }

    private func payload(
        from task: BridgeLiveTaskSnapshot,
        overridingMotionWith snapshot: SessionActivitySnapshot
    ) -> IslandDisplayPayload {
        var mapped = payload(from: task)
        guard shouldPreferSnapshotMotion(snapshot) else { return mapped }
        mapped.motion = avatarMotion(from: snapshot)
        return mapped
    }

    private func shouldPreferSnapshotMotion(_ snapshot: SessionActivitySnapshot) -> Bool {
        switch snapshot.event.lowercased() {
        case "precompact", "postcompact", "worktreecreate":
            return true
        default:
            return false
        }
    }

    private func avatarMotion(from snapshot: SessionActivitySnapshot) -> IslandAvatarMotion {
        switch snapshot.state {
        case .waitingApproval:
            return .notification
        case .sleeping:
            return .sleeping
        case .idle:
            return .idle
        case .active:
            return avatarMotion(
                event: snapshot.event,
                phase: nil,
                toolName: snapshot.toolName,
                action: snapshot.action
            )
        }
    }

    private func avatarMotion(from task: BridgeLiveTaskSnapshot) -> IslandAvatarMotion {
        if task.status == .waitingApproval { return .notification }
        if task.status == .completed { return .happy }
        if task.status == .failed || task.status == .canceled { return .error }
        return avatarMotion(
            event: nil,
            phase: task.phase,
            toolName: task.toolName,
            action: task.action ?? task.summary
        )
    }

    private func avatarMotion(
        event: String?,
        phase: String?,
        toolName: String?,
        action: String?
    ) -> IslandAvatarMotion {
        let event = (event ?? "").lowercased()
        let phase = (phase ?? "").lowercased()
        let tool = (toolName ?? "").lowercased()
        let action = (action ?? "").lowercased()
        let text = [event, phase, tool, action].joined(separator: " ")

        if event == "permissionrequest" || event == "elicitation" || event == "notification" || phase.contains("waiting") {
            return .notification
        }
        if event == "posttoolusefailure" || event == "stopfailure" || phase.contains("failed") || phase.contains("denied") {
            return .error
        }
        if event == "stop" || event == "postcompact" || phase.contains("completed") {
            return .happy
        }
        if event == "precompact" || phase.contains("compact") || text.contains("/clear") {
            return .sweeping
        }
        if event == "worktreecreate" || phase.contains("worktree") || text.contains("worktree") {
            return .carrying
        }
        if event == "subagentstart" || phase.contains("subagent") || tool == "task" || tool.contains("agent") {
            if text.contains("conduct") || text.contains("parallel") || text.contains("multi") || text.contains("2+") || text.contains("3+") {
                return .conducting
            }
            return .juggling
        }
        if event == "userpromptsubmit" || phase.contains("plan") || phase.contains("thinking") || phase.contains("checking") {
            return .thinking
        }
        if tool == "edit" || tool == "write" || tool == "multiedit" || tool.contains("patch") {
            return .building
        }
        if tool == "read" || tool == "glob" || tool == "grep" || tool == "ls" {
            return .thinking
        }
        if event == "pretooluse" || event == "posttooluse" || phase.contains("tool") || phase.contains("running") {
            return .typing
        }
        return .typing
    }

    private func terminalTitle(failed: Bool, canceled: Bool, denied: Bool) -> String {
        if denied { return "Approval Denied" }
        if canceled { return "Task Canceled" }
        if failed { return "Task Failed" }
        return "Task Completed"
    }

    private func terminalFallbackMessage(failed: Bool, canceled: Bool, denied: Bool) -> String {
        if denied { return "The requested action was denied from the island." }
        if canceled { return "Task was canceled before completion." }
        if failed { return "Task stopped before completion." }
        return "Task completed successfully."
    }

    private func liveSubtitle(for task: BridgeLiveTaskSnapshot) -> String {
        let phase = livePhaseTitle(task.phase)
        let repo = repoName(from: task.repo)
        if repo.isEmpty {
            return phase
        }
        return "\(phase) · \(repo)"
    }

    private func liveMetaText(for task: BridgeLiveTaskSnapshot) -> String {
        var parts: [String] = []
        if task.durationSec > 0 {
            parts.append(formatDuration(seconds: task.durationSec))
        }
        if task.inputTokens > 0 {
            parts.append("\(formatCompactTokens(task.inputTokens)) in")
        }
        if task.outputTokens > 0 {
            parts.append("\(formatCompactTokens(task.outputTokens)) out")
        }
        if task.costUSD > 0 {
            parts.append(CostEstimator.formatCost(task.costUSD))
        }
        return parts.joined(separator: " · ")
    }

    private func livePhaseTitle(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Working" }
        let normalized = trimmed
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        return normalized
            .split(separator: " ")
            .map { word in
                let lower = word.lowercased()
                if lower == "ai" { return "AI" }
                return lower.prefix(1).uppercased() + lower.dropFirst()
            }
            .joined(separator: " ")
    }

    private func liveModelLabel(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Claude" }
        let lower = trimmed.lowercased()
        if lower.contains("claude-sonnet") {
            if let version = modelVersionSuffix(from: lower) {
                return "Sonnet \(version)"
            }
            return "Sonnet"
        }
        if lower.contains("claude-opus") {
            if let version = modelVersionSuffix(from: lower) {
                return "Opus \(version)"
            }
            return "Opus"
        }
        if lower.contains("claude-haiku") {
            if let version = modelVersionSuffix(from: lower) {
                return "Haiku \(version)"
            }
            return "Haiku"
        }
        if lower.contains("gpt") && lower.contains("codex") {
            return "Codex"
        }
        if lower.contains("gpt-5.4-mini") { return "GPT-5.4 Mini" }
        if lower.contains("gpt-5.4") { return "GPT-5.4" }
        if lower.contains("gpt-5.3") { return "GPT-5.3" }
        if lower.contains("gpt-4o") { return "GPT-4o" }
        if lower.contains("gemini-2.5-pro") { return "Gemini 2.5 Pro" }
        if lower.contains("gemini-2.5-flash") { return "Gemini 2.5 Flash" }
        if lower.contains("gemini") { return "Gemini" }
        if trimmed.count > 18 {
            return String(trimmed.prefix(15)) + "..."
        }
        return trimmed
    }

    private func modelVersionSuffix(from lower: String) -> String? {
        for candidate in ["4.6", "4.5", "4.1", "4"] where lower.contains(candidate) {
            return candidate
        }
        return nil
    }

    private func repoName(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return URL(fileURLWithPath: trimmed).lastPathComponent
    }

    private func formatDuration(seconds: Int) -> String {
        let total = max(0, seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        if m > 0 { return s > 0 ? "\(m)m \(s)s" : "\(m)m" }
        return "\(s)s"
    }

    private func formatCompactTokens(_ count: Int) -> String {
        if count >= 1_000_000_000 {
            return String(format: "%.1fB", Double(count) / 1_000_000_000)
        }
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        }
        if count >= 1_000 {
            return String(format: "%.0fK", Double(count) / 1_000)
        }
        return "\(count)"
    }

    private func sanitizedTitle(_ raw: String?) -> String {
        guard let raw else { return "" }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        if trimmed.count > 52 {
            return String(trimmed.prefix(49)) + "..."
        }
        return trimmed
    }

    private func sanitizedSubtitle(_ raw: String?) -> String {
        guard let raw else { return "" }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        if trimmed.count > 86 {
            return String(trimmed.prefix(83)) + "..."
        }
        return trimmed
    }
}

private extension NSScreen {
    var cc_isBuiltinDisplay: Bool {
        guard let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return false
        }
        return CGDisplayIsBuiltin(screenNumber) != 0
    }
}

private struct NotchStyleShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))

        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY + topCornerRadius),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY - bottomCornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius + bottomCornerRadius, y: rect.maxY),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius - bottomCornerRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY - bottomCornerRadius),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY + topCornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        return path
    }
}

private struct IslandCapsuleView: View {
    @ObservedObject var model: IslandOverlayModel
    @Namespace private var activityNamespace

    private var compactMode: Bool { model.layout.compact }
    private var hasBridgeApproval: Bool { model.payload.approvalId?.isEmpty == false }
    private var isActionDisabled: Bool { model.isResolving || !hasBridgeApproval }
    private var isRunningMode: Bool { model.payload.state == .running }
    private var isTaskInfoMode: Bool {
        model.payload.state == .running || model.payload.state == .completed || model.payload.state == .failed
    }
    private var isApprovalMode: Bool { model.payload.state == .waitingApproval }
    private var isCollapsedApprovalMode: Bool { compactMode && isApprovalMode }
    private var isCollapsedRunningMode: Bool { compactMode && isRunningMode }
    private var isInteractiveToolApproval: Bool {
        isApprovalMode && model.payload.toolName.caseInsensitiveCompare("AskUserQuestion") == .orderedSame
    }

    // Claude-inspired palette (warm dark + clay accents)
    private var islandBase: Color { .black }
    private var islandTopShade: Color { .black }
    private var borderWarm: Color { Color.white.opacity(0.22) }
    private var textPrimary: Color { Color.white.opacity(0.96) }
    private var textSecondary: Color { Color.white.opacity(0.74) }
    private var accentClay: Color { Color(red: 0.87, green: 0.52, blue: 0.32) }
    private var accentSand: Color { Color(red: 0.79, green: 0.65, blue: 0.49) }
    private var accentBrick: Color { Color(red: 0.66, green: 0.34, blue: 0.27) }

    private let openAnimation = Animation.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
    private let closeAnimation = Animation.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)

    private var topRadius: CGFloat { compactMode ? 6 : 19 }
    private var bottomRadius: CGFloat { compactMode ? 14 : 24 }
    private var shellInnerHorizontalPadding: CGFloat { compactMode ? 14 : 19 }
    private var shellOuterInset: CGFloat { compactMode ? 0 : 12 }
    private var closedSideWidth: CGFloat { max(0, model.layout.notchHeight - 12) + 10 }
    private var compactApprovalIndicatorWidth: CGFloat { 0 }
    private var compactLeadingWidth: CGFloat { closedSideWidth + compactApprovalIndicatorWidth }
    private var compactTrailingWidth: CGFloat { closedSideWidth }
    private var closedCenterWidth: CGFloat {
        if compactMode {
            return max(model.layout.notchWidth - topRadius, 0)
        }
        return max(model.layout.notchWidth - 6, 0)
    }
    private var currentShellAnimation: Animation { compactMode ? closeAnimation : openAnimation }
    private var actionMessage: String {
        let trimmed = model.payload.actionText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Claude is preparing the next step." : trimmed
    }
    private var showsFallbackActions: Bool {
        model.isResolving || !hasBridgeApproval
    }
    private var showActivityHeader: Bool {
        model.payload.state != .hidden
    }
    private var currentAvatarMotion: IslandAvatarMotion { model.payload.motion }
    private var compactAvatarSize: CGSize { CGSize(width: 24, height: 18) }
    private var expandedAvatarSize: CGSize { CGSize(width: 28, height: 20) }

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear

            notchShell
                .frame(width: model.layout.islandWidth, height: model.layout.islandHeight, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var notchShell: some View {
        notchLayout
            .frame(maxWidth: compactMode ? nil : model.layout.islandWidth, alignment: .top)
            .padding(.horizontal, shellInnerHorizontalPadding)
            .padding([.horizontal, .bottom], shellOuterInset)
            .background(islandBase)
            .clipShape(NotchStyleShape(topCornerRadius: topRadius, bottomCornerRadius: bottomRadius))
            .overlay(
                NotchStyleShape(topCornerRadius: topRadius, bottomCornerRadius: bottomRadius)
                    .stroke(borderWarm.opacity(compactMode ? 0.22 : 0.28), lineWidth: 0.6)
            )
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(islandTopShade.opacity(0.96))
                    .frame(height: 1)
                    .padding(.horizontal, topRadius)
            }
            .shadow(color: compactMode ? .clear : .black.opacity(0.7), radius: 6)
            .frame(
                maxWidth: compactMode ? nil : model.layout.islandWidth,
                maxHeight: compactMode ? nil : model.layout.islandHeight,
                alignment: .top
            )
            .animation(currentShellAnimation, value: compactMode)
            .animation(openAnimation, value: model.layout)
            .animation(.easeOut(duration: 0.14), value: model.isResolving)
            .contentShape(Rectangle())
            .onTapGesture {
                if isCollapsedApprovalMode {
                    model.onExpandApproval?()
                } else if isCollapsedRunningMode {
                    model.onExpandRunning?()
                }
            }
    }

    private var notchLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
                .frame(height: max(24, model.layout.notchHeight))

            if !compactMode {
                detailSection
                    .frame(width: max(model.layout.islandWidth - 24, 0), alignment: .leading)
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.8, anchor: .top)
                                .combined(with: .opacity)
                                .combined(with: .offset(y: -10))
                                .animation(.spring(response: 0.35, dampingFraction: 0.82)),
                            removal: .opacity.animation(.easeOut(duration: 0.15))
                        )
                    )
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            if showActivityHeader {
                HStack(spacing: 4) {
                    if let openDashboard = model.onOpenDashboard {
                        Button(action: {
                            if isCollapsedApprovalMode {
                                model.onExpandApproval?()
                            } else if isCollapsedRunningMode {
                                model.onExpandRunning?()
                            } else {
                                openDashboard()
                            }
                        }) {
                            activityAvatar(motion: currentAvatarMotion)
                                .matchedGeometryEffect(id: "avatar", in: activityNamespace, isSource: compactMode)
                        }
                        .buttonStyle(.plain)
                    } else {
                        activityAvatar(motion: currentAvatarMotion)
                            .matchedGeometryEffect(id: "avatar", in: activityNamespace, isSource: compactMode)
                    }

                }
                .frame(width: compactMode ? compactLeadingWidth : nil, alignment: .leading)
                .padding(.leading, compactMode ? 0 : 8)
            }

            if compactMode {
                Rectangle()
                    .fill(.black)
                    .frame(width: closedCenterWidth)
            } else {
                Spacer(minLength: 0)
            }

            if showActivityHeader {
                headerActivityIndicator
                    .matchedGeometryEffect(id: "spinner", in: activityNamespace, isSource: compactMode)
                    .frame(width: compactMode ? compactTrailingWidth : 20, alignment: .center)
                    .padding(.trailing, compactMode ? 4 : 0)
            }
        }
        .frame(height: model.layout.notchHeight)
    }

    @ViewBuilder
    private func activityAvatar(motion: IslandAvatarMotion) -> some View {
        if compactMode {
            ClawdAnimatedAvatar(motion: motion, size: compactAvatarSize)
                .frame(width: compactAvatarSize.width, height: compactAvatarSize.height)
        } else {
            ClawdAnimatedAvatar(motion: motion, size: expandedAvatarSize)
                .frame(width: expandedAvatarSize.width, height: expandedAvatarSize.height)
        }
    }

    @ViewBuilder
    private var headerActivityIndicator: some View {
        switch model.payload.state {
        case .completed:
            terminalCloseButton(
                icon: "checkmark.circle.fill",
                color: Color(red: 0.54, green: 0.82, blue: 0.55)
            )
        case .failed:
            terminalCloseButton(
                icon: "xmark.circle.fill",
                color: accentBrick.opacity(0.95)
            )
        default:
            MiniSpinner(
                color: isApprovalMode ? accentClay : accentSand,
                animating: true,
                size: compactMode ? 12 : 13
            )
        }
    }

    private func terminalCloseButton(icon: String, color: Color) -> some View {
        Button {
            model.onDismiss?()
        } label: {
            Image(systemName: icon)
                .font(.system(size: compactMode ? 12 : 13, weight: .bold))
                .foregroundColor(color)
                .frame(width: 22, height: 22)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Close")
    }

    private var detailSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.payload.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(textPrimary)
                        .lineLimit(1)

                    Text(model.payload.subtitle)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(textSecondary.opacity(0.88))
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                if !model.payload.toolName.isEmpty {
                    if let openChat = model.onOpenChat {
                        Button(action: openChat) {
                            toolPill(text: model.payload.toolName)
                        }
                        .buttonStyle(.plain)
                    } else {
                        toolPill(text: model.payload.toolName)
                    }
                }
            }

            Text(actionMessage)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundColor(textPrimary.opacity(0.92))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(Color.white.opacity(0.028))
                        .overlay(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .stroke(Color.white.opacity(0.10), lineWidth: 0.55)
                        )
                )

            if !model.payload.metaText.isEmpty {
                Text(model.payload.metaText)
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(accentSand.opacity(0.95))
                    .lineLimit(1)
                    .padding(.horizontal, 4)
            }

            if isTaskInfoMode {
                HStack(spacing: 8) {
                    if let openChat = model.onOpenChat {
                        iconActionButton(icon: "bubble.left", action: openChat)
                    }

                    if let openDashboard = model.onOpenDashboard {
                        terminalActionButton(title: "Dashboard", action: openDashboard)
                    }

                    Spacer(minLength: 0)
                }
                .foregroundColor(textPrimary)
            } else if isInteractiveToolApproval {
                HStack(spacing: 8) {
                    if let openChat = model.onOpenChat {
                        iconActionButton(icon: "bubble.left", action: openChat)
                    }

                    if let openTerminal = model.onOpenTerminal {
                        terminalActionButton(title: "Terminal", action: openTerminal)
                    } else {
                        Text("Open terminal to answer")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(textSecondary.opacity(0.72))
                    }

                    Spacer(minLength: 0)
                }
                .foregroundColor(textPrimary)
            } else if showsFallbackActions {
                HStack(spacing: 8) {
                    if let openChat = model.onOpenChat {
                        iconActionButton(icon: "bubble.left", action: openChat)
                    }

                    Spacer(minLength: 0)

                    if model.isResolving {
                        Text("Sending...")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(textSecondary.opacity(0.86))
                    } else {
                        Text("Use terminal to continue")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(textSecondary.opacity(0.72))
                    }
                }
                .foregroundColor(textPrimary)
            } else {
                HStack(spacing: 8) {
                    if let openChat = model.onOpenChat {
                        iconActionButton(icon: "bubble.left", action: openChat)
                    }

                    actionButton(title: "Deny", fill: accentBrick.opacity(0.24), stroke: accentBrick.opacity(0.42), expand: true) {
                        model.onReject?()
                    }

                    actionButton(title: "Allow", fill: accentClay.opacity(0.26), stroke: accentClay.opacity(0.5), expand: true) {
                        model.onApprove?()
                    }
                }
                .foregroundColor(textPrimary)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    private func statusPill(text: String, fill: Color, stroke: Color, textColor: Color) -> some View {
        Text(text.uppercased())
            .font(.system(size: 8.5, weight: .bold))
            .foregroundColor(textColor)
            .tracking(0.4)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(fill)
            .overlay(
                RoundedRectangle(cornerRadius: 999, style: .continuous)
                    .stroke(stroke, lineWidth: 0.5)
            )
            .clipShape(Capsule())
    }

    private func toolColors(for text: String) -> (fill: Color, stroke: Color) {
        switch text.lowercased() {
        case "bash":
            return (accentClay.opacity(0.92), accentClay.opacity(0.0))
        case "edit":
            return (Color(red: 0.28, green: 0.42, blue: 0.71), Color.white.opacity(0.0))
        case "write":
            return (Color(red: 0.46, green: 0.39, blue: 0.68), Color.white.opacity(0.0))
        case "read":
            return (Color(red: 0.30, green: 0.56, blue: 0.40), Color.white.opacity(0.0))
        case "glob", "grep":
            return (Color(red: 0.28, green: 0.52, blue: 0.58), Color.white.opacity(0.0))
        case "agent":
            return (Color(red: 0.62, green: 0.43, blue: 0.53), Color.white.opacity(0.0))
        case "preview":
            return (Color.white.opacity(0.12), Color.white.opacity(0.14))
        default:
            return (Color.white.opacity(0.08), Color.white.opacity(0.14))
        }
    }

    private func toolPill(text: String) -> some View {
        let colors = toolColors(for: text)
        return Text(text.uppercased())
            .font(.system(size: 9.5, weight: .bold))
            .foregroundColor(.white)
            .tracking(0.38)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(colors.fill)
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(colors.stroke, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func iconActionButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(textSecondary.opacity(0.9))
                .frame(width: 28, height: 28)
                .background(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func terminalActionButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "terminal")
                    .font(.system(size: 10, weight: .medium))
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(.black)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.92))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func actionButton(
        title: String,
        fill: Color,
        stroke: Color,
        expand: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .frame(maxWidth: expand ? .infinity : nil)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(fill)
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(stroke, lineWidth: 0.5)
                )
                .cornerRadius(9)
        }
        .buttonStyle(.plain)
        .disabled(isActionDisabled)
    }
}

private struct ClawdAnimatedAvatar: View {
    var motion: IslandAvatarMotion
    var size: CGSize

    @State private var frameIndex = 0
    @State private var timer: Timer?

    private static let motionFrames: [IslandAvatarMotion: [String]] = [
        .idle: ["clawd-idle-f0", "clawd-idle-f1"],
        .thinking: ["clawd-thinking-f0", "clawd-thinking-f1"],
        .typing: ["clawd-typing-f0", "clawd-typing-f1", "clawd-typing-f2"],
        .building: ["clawd-typing-f0", "clawd-typing-f1", "clawd-typing-f2"],
        .juggling: ["clawd-happy-f0", "clawd-happy-f1", "clawd-happy-f2"],
        .conducting: ["clawd-thinking-f0", "clawd-thinking-f1"],
        .notification: ["clawd-thinking-f0", "clawd-thinking-f1"],
        .error: ["clawd-error-f0"],
        .happy: ["clawd-happy-f0", "clawd-happy-f1", "clawd-happy-f2"],
        .sweeping: ["clawd-idle-f0", "clawd-idle-f1"],
        .carrying: ["clawd-typing-f1", "clawd-typing-f2"],
        .sleeping: ["clawd-sleeping-f0", "clawd-sleeping-f1", "clawd-sleeping-f2"],
    ]

    private static let frameIntervals: [IslandAvatarMotion: TimeInterval] = [
        .idle: 0.62,
        .thinking: 0.42,
        .typing: 0.15,
        .building: 0.16,
        .juggling: 0.18,
        .conducting: 0.28,
        .notification: 0.34,
        .error: 0.35,
        .happy: 0.16,
        .sweeping: 0.22,
        .carrying: 0.18,
        .sleeping: 0.82,
    ]

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                avatarImage
                    .scaleEffect(avatarScale(at: time))
                    .rotationEffect(.degrees(avatarRotation(at: time)))
                    .offset(avatarOffset(at: time))

                ClawdMotionOverlay(motion: motion, size: size, time: time)
            }
            .frame(width: size.width, height: size.height)
        }
        .frame(width: size.width, height: size.height)
        .onAppear { startAnimation() }
        .onDisappear { stopAnimation() }
        .onChange(of: motion) { _ in
            frameIndex = 0
            startAnimation()
        }
    }

    @ViewBuilder
    private var avatarImage: some View {
        if let image = currentImage {
            Image(nsImage: image)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
        } else {
            Image(systemName: fallbackSymbol)
                .resizable()
                .scaledToFit()
                .foregroundColor(.white.opacity(0.82))
                .padding(2)
        }
    }

    private var fallbackSymbol: String {
        switch motion {
        case .notification:
            return "bell.badge.fill"
        case .error:
            return "xmark.octagon.fill"
        case .happy:
            return "sparkles"
        case .sleeping:
            return "moon.zzz.fill"
        default:
            return "ellipsis.message.fill"
        }
    }

    private var currentImage: NSImage? {
        let frames = Self.motionFrames[motion] ?? Self.motionFrames[.idle] ?? []
        guard !frames.isEmpty else { return nil }
        let frameName = frames[frameIndex % frames.count]
        return StatusBarController.loadClawdImage(frameName: frameName)
    }

    private func avatarScale(at time: TimeInterval) -> CGFloat {
        switch motion {
        case .idle:
            return 1.0 + wave(time, period: 2.8) * 0.025
        case .happy:
            return 1.0 + positiveWave(time, period: 0.62) * 0.12
        case .notification:
            return 1.0 + positiveWave(time, period: 1.05) * 0.055
        case .carrying:
            return 0.98 + positiveWave(time, period: 0.48) * 0.055
        default:
            return 1.0
        }
    }

    private func avatarRotation(at time: TimeInterval) -> Double {
        switch motion {
        case .juggling:
            return Double(wave(time, period: 0.72)) * 3.2
        case .conducting:
            return Double(wave(time, period: 0.58)) * 2.4
        case .error:
            return Double(wave(time, period: 0.12)) * 2.5
        default:
            return 0
        }
    }

    private func avatarOffset(at time: TimeInterval) -> CGSize {
        switch motion {
        case .typing, .building:
            return CGSize(width: wave(time, period: 0.3) * 0.45, height: 0)
        case .happy:
            return CGSize(width: 0, height: -positiveWave(time, period: 0.46) * 1.1)
        case .error:
            return CGSize(width: wave(time, period: 0.11) * 1.0, height: wave(time, period: 0.17) * 0.45)
        case .sweeping:
            return CGSize(width: wave(time, period: 0.74) * 0.9, height: 0)
        default:
            return .zero
        }
    }

    private func startAnimation() {
        stopAnimation()
        let frames = Self.motionFrames[motion] ?? []
        guard frames.count > 1 else { return }
        let interval = Self.frameIntervals[motion] ?? 0.2
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            frameIndex = (frameIndex + 1) % frames.count
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func stopAnimation() {
        timer?.invalidate()
        timer = nil
    }

    private func wave(_ time: TimeInterval, period: Double, phase: Double = 0) -> CGFloat {
        CGFloat(sin(((time / period) + phase) * 2.0 * Double.pi))
    }

    private func positiveWave(_ time: TimeInterval, period: Double, phase: Double = 0) -> CGFloat {
        (wave(time, period: period, phase: phase) + 1.0) / 2.0
    }
}

private struct ClawdMotionOverlay: View {
    var motion: IslandAvatarMotion
    var size: CGSize
    var time: TimeInterval

    private let clay = Color(red: 0.87, green: 0.52, blue: 0.32)
    private let sand = Color(red: 0.79, green: 0.65, blue: 0.49)
    private let brick = Color(red: 0.66, green: 0.34, blue: 0.27)
    private let sky = Color(red: 0.38, green: 0.72, blue: 0.88)

    var body: some View {
        ZStack {
            switch motion {
            case .idle:
                idleOverlay
            case .thinking:
                thinkingOverlay
            case .typing:
                typingOverlay
            case .building:
                buildingOverlay
            case .juggling:
                jugglingOverlay
            case .conducting:
                conductingOverlay
            case .notification:
                notificationOverlay
            case .error:
                errorOverlay
            case .happy:
                happyOverlay
            case .sweeping:
                sweepingOverlay
            case .carrying:
                carryingOverlay
            case .sleeping:
                sleepingOverlay
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    private var idleOverlay: some View {
        Circle()
            .fill(Color.white.opacity(0.75 + positiveWave(period: 3.4) * 0.2))
            .frame(width: max(1.4, size.width * 0.08), height: max(1.4, size.width * 0.08))
            .offset(x: -size.width * 0.33, y: -size.height * 0.42)
    }

    private var thinkingOverlay: some View {
        HStack(spacing: 1.7) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(sand.opacity(0.35 + positiveWave(period: 1.0, phase: Double(index) * 0.18) * 0.58))
                    .frame(width: 2.2, height: 2.2)
                    .offset(y: -positiveWave(period: 0.78, phase: Double(index) * 0.18) * 2.0)
            }
        }
        .offset(x: size.width * 0.34, y: -size.height * 0.48)
    }

    private var typingOverlay: some View {
        HStack(spacing: 1.2) {
            ForEach(0..<3, id: \.self) { index in
                RoundedRectangle(cornerRadius: 0.7, style: .continuous)
                    .fill(sky.opacity(0.55 + positiveWave(period: 0.52, phase: Double(index) * 0.2) * 0.35))
                    .frame(width: 2.4, height: 1.3 + positiveWave(period: 0.52, phase: Double(index) * 0.2) * 3.0)
            }
        }
        .offset(x: size.width * 0.35, y: size.height * 0.28)
    }

    private var buildingOverlay: some View {
        ZStack {
            block(x: size.width * 0.28, y: size.height * 0.26, color: clay.opacity(0.9))
            block(x: size.width * 0.40, y: size.height * 0.26, color: sand.opacity(0.95))
            block(
                x: size.width * 0.34,
                y: size.height * (0.08 - positiveWave(period: 0.7) * 0.08),
                color: sky.opacity(0.92)
            )
        }
    }

    private var jugglingOverlay: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                let angle = ((time / 1.15) + Double(index) / 3.0) * 2.0 * Double.pi
                Circle()
                    .fill([clay, sand, sky][index].opacity(0.95))
                    .frame(width: 3.2, height: 3.2)
                    .offset(
                        x: CGFloat(cos(angle)) * size.width * 0.38,
                        y: -size.height * 0.34 + CGFloat(sin(angle)) * size.height * 0.26
                    )
            }
        }
    }

    private var conductingOverlay: some View {
        ZStack {
            Path { path in
                path.move(to: CGPoint(x: size.width * 0.58, y: size.height * 0.24))
                path.addLine(to: CGPoint(
                    x: size.width * (0.78 + wave(period: 0.5) * 0.08),
                    y: size.height * (0.04 + positiveWave(period: 0.5) * 0.16)
                ))
            }
            .stroke(sand.opacity(0.9), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))

            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(sky.opacity(0.45 + positiveWave(period: 0.86, phase: Double(index) * 0.22) * 0.42))
                    .frame(width: 2.1, height: 2.1)
                    .offset(x: size.width * (0.22 + CGFloat(index) * 0.18), y: -size.height * (0.38 + positiveWave(period: 0.86, phase: Double(index) * 0.22) * 0.18))
            }
        }
    }

    private var notificationOverlay: some View {
        ZStack {
            Circle()
                .stroke(clay.opacity(0.55 - positiveWave(period: 1.0) * 0.25), lineWidth: 1.1)
                .frame(width: 8 + positiveWave(period: 1.0) * 6, height: 8 + positiveWave(period: 1.0) * 6)
            Circle()
                .fill(clay.opacity(0.92))
                .frame(width: 4.6, height: 4.6)
        }
        .offset(x: size.width * 0.43, y: -size.height * 0.25)
    }

    private var errorOverlay: some View {
        ZStack {
            Path { path in
                path.move(to: CGPoint(x: size.width * 0.68, y: size.height * 0.08))
                path.addLine(to: CGPoint(x: size.width * 0.86, y: size.height * 0.28))
                path.move(to: CGPoint(x: size.width * 0.86, y: size.height * 0.08))
                path.addLine(to: CGPoint(x: size.width * 0.68, y: size.height * 0.28))
            }
            .stroke(brick.opacity(0.95), style: StrokeStyle(lineWidth: 1.35, lineCap: .round))
            .offset(x: wave(period: 0.13) * 0.8)
        }
    }

    private var happyOverlay: some View {
        ZStack {
            ForEach(0..<5, id: \.self) { index in
                let angle = (Double(index) / 5.0) * 2.0 * Double.pi
                let spread = 0.55 + positiveWave(period: 0.72, phase: Double(index) * 0.12) * 0.45
                Circle()
                    .fill([clay, sand, sky, Color.white.opacity(0.86), clay][index])
                    .frame(width: 2.4, height: 2.4)
                    .offset(
                        x: CGFloat(cos(angle)) * size.width * 0.46 * spread,
                        y: CGFloat(sin(angle)) * size.height * 0.44 * spread - size.height * 0.14
                    )
            }
        }
    }

    private var sweepingOverlay: some View {
        Path { path in
            path.move(to: CGPoint(x: size.width * 0.15, y: size.height * 0.82))
            path.addQuadCurve(
                to: CGPoint(x: size.width * 0.90, y: size.height * 0.78),
                control: CGPoint(
                    x: size.width * (0.42 + wave(period: 0.74) * 0.12),
                    y: size.height * (0.98 - positiveWave(period: 0.74) * 0.22)
                )
            )
        }
        .stroke(sand.opacity(0.72), style: StrokeStyle(lineWidth: 1.25, lineCap: .round))
    }

    private var carryingOverlay: some View {
        RoundedRectangle(cornerRadius: 1.4, style: .continuous)
            .fill(sand.opacity(0.92))
            .frame(width: size.width * 0.28, height: size.height * 0.26)
            .overlay(
                RoundedRectangle(cornerRadius: 1.2, style: .continuous)
                    .stroke(clay.opacity(0.85), lineWidth: 0.75)
            )
            .offset(x: size.width * 0.36, y: size.height * (0.23 - positiveWave(period: 0.5) * 0.08))
    }

    private var sleepingOverlay: some View {
        Text("Z")
            .font(.system(size: max(5, size.height * 0.52), weight: .bold, design: .rounded))
            .foregroundColor(Color.white.opacity(0.55 + positiveWave(period: 1.4) * 0.32))
            .offset(x: size.width * 0.38, y: -size.height * (0.38 + positiveWave(period: 1.4) * 0.22))
    }

    private func block(x: CGFloat, y: CGFloat, color: Color) -> some View {
        RoundedRectangle(cornerRadius: 1.0, style: .continuous)
            .fill(color)
            .frame(width: 3.7, height: 3.4)
            .offset(x: x, y: y)
    }

    private func wave(period: Double, phase: Double = 0) -> CGFloat {
        CGFloat(sin(((time / period) + phase) * 2.0 * Double.pi))
    }

    private func positiveWave(period: Double, phase: Double = 0) -> CGFloat {
        (wave(period: period, phase: phase) + 1.0) / 2.0
    }
}

private struct WarmPulseBars: View {
    var color: Color
    var pulsing: Bool

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(color.opacity(0.9 - Double(index) * 0.15))
                    .frame(width: 3.5, height: barHeight(for: index))
            }
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        let base: [CGFloat] = [7, 11, 8]
        let pulse: [CGFloat] = [10, 6, 12]
        return pulsing ? pulse[index] : base[index]
    }
}

private struct MiniSpinner: View {
    var color: Color
    var animating: Bool
    var size: CGFloat = 13
    @State private var rotate = false
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.2), lineWidth: 1.2)

            ZStack {
                Circle()
                    .trim(from: 0.07, to: 0.68)
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: [
                                color.opacity(0.15),
                                color,
                                color.opacity(0.78),
                            ]),
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 1.9, lineCap: .round)
                    )

                Circle()
                    .fill(color.opacity(0.96))
                    .frame(width: 2.8, height: 2.8)
                    .shadow(color: color.opacity(0.62), radius: 1.6, x: 0, y: 0)
                    .offset(y: -(size / 2 - 1.1))
            }
            .rotationEffect(.degrees(rotate ? 360 : 0))

            Circle()
                .fill(color.opacity(0.16))
                .frame(width: 4.0, height: 4.0)
                .blur(radius: pulse ? 0.85 : 0.2)
        }
        .frame(width: size, height: size)
        .scaleEffect(animating ? (pulse ? 1.0 : 0.9) : 0.9)
        .opacity(animating ? 1.0 : 0.65)
            .onAppear { updateAnimation() }
            .onChange(of: animating) { _ in updateAnimation() }
    }

    private func updateAnimation() {
        guard animating else {
            rotate = false
            pulse = false
            return
        }

        rotate = false
        pulse = false

        withAnimation(.linear(duration: 1.02).repeatForever(autoreverses: false)) {
            rotate = true
        }
        withAnimation(.easeInOut(duration: 0.68).repeatForever(autoreverses: true)) {
            pulse = true
        }
    }
}

@MainActor
enum IslandSnapshotRenderer {
    enum PreviewMode: String {
        case compactRunning
        case compactApproval
        case expandedApproval
    }

    static func renderPreview(to path: String, mode: PreviewMode = .expandedApproval) throws {
        let model = IslandOverlayModel()
        let isCompact = mode != .expandedApproval
        let isApproval = mode != .compactRunning
        model.payload = IslandDisplayPayload(
            state: isApproval ? .waitingApproval : .running,
            title: isApproval ? "Permission Request" : "Claude is coding",
            subtitle: isApproval ? "Review this action before Claude continues." : "Active task in progress",
            toolName: isApproval ? "Edit" : "Claude",
            actionText: isApproval
                ? "/Users/zhangzhengtian02/Workspace/sailor_fe_c_kmp/.../IslandOverlay.swift"
                : "Updating island layout and motion tuning",
            approvalId: isApproval ? "snapshot-preview" : nil,
            taskId: isApproval ? "snapshot-approval" : "snapshot-running",
            metaText: isApproval ? "" : "12m · 480K in · 42K out · $1.28"
        )
        model.layout = IslandLayout(
            notchWidth: 190,
            notchHeight: 38,
            islandWidth: isCompact ? 302 : 480,
            islandHeight: isCompact ? 40 : 208,
            compact: isCompact
        )

        let root = IslandCapsuleView(model: model)
            .frame(width: model.layout.islandWidth, height: model.layout.islandHeight)

        let hosting = NSHostingView(rootView: root)
        let size = NSSize(width: model.layout.islandWidth, height: model.layout.islandHeight)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw NSError(domain: "IslandSnapshotRenderer", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create bitmap image rep"
            ])
        }
        rep.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: rep)

        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "IslandSnapshotRenderer", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Failed to encode PNG"
            ])
        }
        try pngData.write(to: URL(fileURLWithPath: path))
    }
}
