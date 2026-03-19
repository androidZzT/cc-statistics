import SwiftUI
import Combine
import Carbon.HIToolbox
import ServiceManagement

// MARK: - PanelManager

final class PanelManager: ObservableObject {
    private var panel: FloatingPanel?
    private var closeObserver: Any?

    func show<Content: View>(content: Content, onClose: @escaping () -> Void) {
        if let existing = panel {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let hostingView = NSHostingView(rootView: content)
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        let rect = NSRect(x: 0, y: 0, width: 420, height: 600)
        let newPanel = FloatingPanel(contentRect: rect)

        if let container = newPanel.contentView {
            container.addSubview(hostingView)
            NSLayoutConstraint.activate([
                hostingView.topAnchor.constraint(equalTo: container.topAnchor),
                hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
        }

        newPanel.positionAtRightCenter()
        newPanel.makeKeyAndOrderFront(nil)

        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: newPanel,
            queue: .main
        ) { [weak self] _ in
            onClose()
            self?.panel = nil
        }

        self.panel = newPanel
    }

    func close() {
        panel?.close()
        panel = nil
        if let obs = closeObserver {
            NotificationCenter.default.removeObserver(obs)
            closeObserver = nil
        }
    }

    func updateAppearance(_ appearance: NSAppearance?) {
        panel?.appearance = appearance
    }
}

// MARK: - Global Hotkey Manager

class HotkeyManager {
    private var eventHandler: EventHandlerRef?
    private let callback: () -> Void

    /// Register a global hotkey: Command+Shift+C
    init(callback: @escaping () -> Void) {
        self.callback = callback
        registerHotkey()
    }

    private func registerHotkey() {
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(0x43435354) // "CCST"
        hotKeyID.id = 1

        var eventType = EventTypeSpec()
        eventType.eventClass = OSType(kEventClassKeyboard)
        eventType.eventKind = OSType(kEventHotKeyPressed)

        // Store self as pointer for the C callback
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let userData = userData else { return OSStatus(eventNotHandledErr) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    manager.callback()
                }
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &eventHandler
        )

        // Command+Shift+C  (kVK_ANSI_C = 0x08)
        var hotKeyRef: EventHotKeyRef?
        RegisterEventHotKey(
            UInt32(kVK_ANSI_C),
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }
}

// MARK: - Claude Logo Icon

let claudeBitmap: [[Int]] = [
    [0,0,0,1,1,1,1,1,1,1,1,1,1,1,1,0,0,0],
    [0,0,0,1,1,0,1,1,1,1,1,1,0,1,1,0,0,0],
    [0,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,0],
    [0,0,0,1,1,1,1,1,1,1,1,1,1,1,1,0,0,0],
    [0,0,0,0,1,0,1,0,0,0,0,1,0,1,0,0,0,0],
]

func drawClaudeLogo(size: NSSize) -> NSImage {
    let image = NSImage(size: size, flipped: true) { rect in
        let cols = claudeBitmap[0].count
        let rows = claudeBitmap.count
        let pixW = rect.width / CGFloat(cols)
        let pixH = pixW * 2.0
        let totalH = pixH * CGFloat(rows)
        let scale = min(1.0, rect.height / totalH)
        let pw = pixW * scale
        let ph = pixH * scale
        let totalW = pw * CGFloat(cols)
        let th = ph * CGFloat(rows)
        let xOff = (rect.width - totalW) / 2.0
        let yOff = (rect.height - th) / 2.0

        let ctx = NSGraphicsContext.current!.cgContext
        ctx.setFillColor(NSColor.black.cgColor)
        for row in 0..<rows {
            for col in 0..<cols {
                if claudeBitmap[row][col] == 1 {
                    let x = xOff + CGFloat(col) * pw
                    let y = yOff + CGFloat(row) * ph
                    let pixel = CGRect(x: x, y: y, width: pw + 0.5, height: ph + 0.5)
                    let path = CGPath(roundedRect: pixel,
                                      cornerWidth: pw * 0.15,
                                      cornerHeight: ph * 0.15,
                                      transform: nil)
                    ctx.addPath(path)
                }
            }
        }
        ctx.fillPath()
        return true
    }
    image.isTemplate = true
    return image
}

// MARK: - Status Bar Display Mode

enum StatusBarDisplayMode: String {
    case tokenAndCost = "token_cost"
    case tokenOnly = "token"
    case costOnly = "cost"
    case sessionCount = "sessions"
}

// MARK: - StatusBarController

class StatusBarController {
    private(set) var statusItem: NSStatusItem
    private let onToggle: () -> Void
    private let onToggleChat: () -> Void
    var displayMode: StatusBarDisplayMode = .tokenAndCost

    // Cached values for re-rendering on mode switch
    private var lastTokens: Int = 0
    private var lastCost: Double = 0
    private var lastSessions: Int = 0

    private var iconView: NSImageView!
    private var label1: NSTextField!
    private var label2: NSTextField!

    init(onToggle: @escaping () -> Void, onToggleChat: @escaping () -> Void) {
        self.onToggle = onToggle
        self.onToggleChat = onToggleChat
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.action = #selector(handleClick(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])

            // Custom layout: icon + stacked labels
            let icon = NSImageView()
            icon.image = drawClaudeLogo(size: NSSize(width: 22, height: 22))
            icon.translatesAutoresizingMaskIntoConstraints = false

            let l1 = NSTextField(labelWithString: "")
            l1.font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
            l1.textColor = .headerTextColor
            l1.alignment = .left
            l1.translatesAutoresizingMaskIntoConstraints = false

            let l2 = NSTextField(labelWithString: "")
            l2.font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
            l2.textColor = .headerTextColor
            l2.alignment = .left
            l2.translatesAutoresizingMaskIntoConstraints = false

            let stack = NSStackView(views: [l1, l2])
            stack.orientation = .vertical
            stack.spacing = -1
            stack.alignment = .leading
            stack.translatesAutoresizingMaskIntoConstraints = false

            let container = NSStackView(views: [icon, stack])
            container.orientation = .horizontal
            container.spacing = 3
            container.alignment = .centerY
            container.translatesAutoresizingMaskIntoConstraints = false

            button.addSubview(container)
            NSLayoutConstraint.activate([
                container.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                container.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 4),
                container.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -4),
                icon.widthAnchor.constraint(equalToConstant: 22),
                icon.heightAnchor.constraint(equalToConstant: 22),
            ])

            self.iconView = icon
            self.label1 = l1
            self.label2 = l2
        }
    }

    @objc func handleClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            showContextMenu()
        } else {
            onToggle()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()

        // Display mode submenu
        let displayMenu = NSMenu()
        let modes: [(StatusBarDisplayMode, String)] = [
            (.tokenAndCost, "Token + \(L10n.cost)"),
            (.tokenOnly, "Token"),
            (.costOnly, L10n.cost),
            (.sessionCount, L10n.sessions),
        ]
        for (mode, title) in modes {
            let item = NSMenuItem(title: title, action: #selector(switchDisplayMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            if displayMode == mode { item.state = .on }
            displayMenu.addItem(item)
        }
        let displayItem = NSMenuItem(title: L10n.statusBarDisplay, action: nil, keyEquivalent: "")
        displayItem.submenu = displayMenu
        menu.addItem(displayItem)

        menu.addItem(NSMenuItem.separator())

        // Launch at login
        let loginItem = NSMenuItem(title: L10n.launchAtLogin, action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        loginItem.target = self
        if #available(macOS 13.0, *) {
            loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
        menu.addItem(loginItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: L10n.showDashboard, action: #selector(showDashboard), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: L10n.showChat, action: #selector(showChat), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: L10n.quit, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)
        for item in menu.items where item.target == nil { item.target = self }

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc func switchDisplayMode(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String,
           let mode = StatusBarDisplayMode(rawValue: raw) {
            displayMode = mode
            refreshLabel()
        }
    }

    @objc func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        if #available(macOS 13.0, *) {
            do {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                } else {
                    try SMAppService.mainApp.register()
                }
            } catch {}
        }
    }

    @objc func showDashboard() { onToggle() }
    @objc func showChat() { onToggleChat() }

    var isOverLimit: Bool = false

    func updateTokenLabel(_ totalTokens: Int, cost: Double = 0, sessions: Int = 0, overLimit: Bool = false) {
        lastTokens = totalTokens
        lastCost = cost
        lastSessions = sessions
        isOverLimit = overLimit
        refreshLabel()
    }

    private func refreshLabel() {
        guard let button = statusItem.button else { return }

        var line1 = ""
        var line2 = ""

        switch displayMode {
        case .tokenAndCost:
            if lastTokens > 0 { line1 = Self.formatTokens(lastTokens) }
            if lastCost > 0 { line2 = CostEstimator.formatCost(lastCost) }
        case .tokenOnly:
            if lastTokens > 0 { line1 = Self.formatTokens(lastTokens) }
        case .costOnly:
            if lastCost > 0 { line1 = CostEstimator.formatCost(lastCost) }
        case .sessionCount:
            if lastSessions > 0 { line1 = "\(lastSessions)" }
        }

        let labelColor: NSColor = isOverLimit ? .systemRed : .headerTextColor
        label1.textColor = labelColor
        label2.textColor = labelColor
        label1.stringValue = line1
        label2.stringValue = line2
        label2.isHidden = line2.isEmpty
    }

    private static func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000_000 { return String(format: "%.1fB", Double(n) / 1e9) }
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1e6) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1e3) }
        return "\(n)"
    }
}

// MARK: - AppDelegate

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    let viewModel = StatsViewModel()
    let panelManager = PanelManager()

    var statusBarController: StatusBarController?
    var mainWindow: NSWindow?
    var hotkeyManager: HotkeyManager?
    var eventMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusBar()
        setupGlobalHotkey()
        observeConversationPanel()
        observeTokenUsage()
        observeTheme()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    // MARK: - Status Bar

    private func setupStatusBar() {
        statusBarController = StatusBarController(
            onToggle: { [weak self] in
                self?.toggleMainWindow()
            },
            onToggleChat: { [weak self] in
                self?.viewModel.toggleConversationPanel()
            }
        )
    }

    // MARK: - Global Hotkey (Cmd+Shift+C)

    private func setupGlobalHotkey() {
        hotkeyManager = HotkeyManager { [weak self] in
            Task { @MainActor in
                self?.toggleMainWindow()
            }
        }
    }

    // MARK: - Main Window

    private func toggleMainWindow() {
        if let window = mainWindow, window.isVisible {
            hideMainWindowAnimated()
        } else {
            showMainWindow()
        }
    }

    private func hideMainWindowAnimated() {
        guard let window = mainWindow else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }, completionHandler: {
            window.orderOut(nil)
            window.alphaValue = 1
        })
    }

    private func showMainWindowAnimated(_ window: NSWindow) {
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
    }

    private func positionWindowBelowStatusBar(_ window: NSWindow) {
        if let button = statusBarController?.statusItem.button,
           let buttonWindow = button.window {
            let buttonRect = button.convert(button.bounds, to: nil)
            let screenRect = buttonWindow.convertToScreen(buttonRect)
            let screen = buttonWindow.screen ?? NSScreen.main ?? NSScreen.screens.first!
            let visibleFrame = screen.visibleFrame

            var x = screenRect.midX - window.frame.width / 2
            let y = screenRect.minY - window.frame.height - 4

            // Clamp to screen edges
            x = max(visibleFrame.minX + 4, min(x, visibleFrame.maxX - window.frame.width - 4))

            window.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            if let screen = NSScreen.main {
                let visibleFrame = screen.visibleFrame
                let x = visibleFrame.midX - window.frame.width / 2
                let y = visibleFrame.maxY - window.frame.height - 8
                window.setFrameOrigin(NSPoint(x: x, y: y))
            }
        }
    }

    private func showMainWindow() {
        if let window = mainWindow {
            positionWindowBelowStatusBar(window)
            showMainWindowAnimated(window)
            return
        }

        let contentView = DashboardView(viewModel: viewModel)
            .frame(minWidth: 480, minHeight: 500)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 660),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        // 隐藏标题栏按钮
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        panel.backgroundColor = .windowBackgroundColor
        panel.contentView = NSHostingView(rootView: contentView)
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        applyThemeToPanel(panel)

        // 圆角
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = 12
        panel.contentView?.layer?.masksToBounds = true

        positionWindowBelowStatusBar(panel)
        self.mainWindow = panel
        showMainWindowAnimated(panel)

        // 全局监听鼠标点击，点击面板外部自动收起（带动画）
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self, let window = self.mainWindow, window.isVisible else { return }
            self.hideMainWindowAnimated()
        }
    }

    // MARK: - Theme

    private func applyThemeToPanel(_ panel: NSPanel) {
        let theme = viewModel.themeMode
        switch theme {
        case "dark":
            panel.appearance = NSAppearance(named: .darkAqua)
        case "light":
            panel.appearance = NSAppearance(named: .aqua)
        default:
            panel.appearance = nil  // follow system
        }
    }

    private func observeTheme() {
        viewModel.$themeMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] theme in
                guard let self = self else { return }
                if let window = self.mainWindow as? NSPanel {
                    self.applyThemeToPanel(window)
                }
                // 同步更新对话面板
                let panelAppearance: NSAppearance?
                switch theme {
                case "dark": panelAppearance = NSAppearance(named: .darkAqua)
                case "light": panelAppearance = NSAppearance(named: .aqua)
                default: panelAppearance = nil
                }
                self.panelManager.updateAppearance(panelAppearance)
            }
            .store(in: &cancellables)
    }

    // MARK: - Token Usage in Status Bar

    private func observeTokenUsage() {
        viewModel.$todayTokens
            .combineLatest(viewModel.$todayCost, viewModel.$todaySessions)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tokens, cost, sessions in
                guard let self = self else { return }
                let overLimit = self.viewModel.isOverDailyLimit || self.viewModel.isOverWeeklyLimit
                self.statusBarController?.updateTokenLabel(tokens, cost: cost, sessions: sessions, overLimit: overLimit)
            }
            .store(in: &cancellables)
    }

    // MARK: - Conversation Panel

    private func observeConversationPanel() {
        viewModel.$showConversationPanel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] show in
                guard let self = self else { return }
                if show {
                    self.panelManager.show(
                        content: ConversationView(
                            sessions: self.viewModel.recentSessions,
                            onClose: {
                                Task { @MainActor in
                                    self.viewModel.showConversationPanel = false
                                }
                            }
                        ),
                        onClose: {
                            Task { @MainActor in
                                self.viewModel.showConversationPanel = false
                            }
                        }
                    )
                } else {
                    self.panelManager.close()
                }
            }
            .store(in: &cancellables)
    }
}

// MARK: - App

@main
struct CCStatsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
