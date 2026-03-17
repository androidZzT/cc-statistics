import SwiftUI
import Combine
import Carbon.HIToolbox

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

// MARK: - StatusBarController

class StatusBarController {
    private(set) var statusItem: NSStatusItem
    private let onToggle: () -> Void
    private let onToggleChat: () -> Void

    init(onToggle: @escaping () -> Void, onToggleChat: @escaping () -> Void) {
        self.onToggle = onToggle
        self.onToggleChat = onToggleChat
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "CC Stats")
            button.image?.size = NSSize(width: 18, height: 18)
            button.image?.isTemplate = true
            button.action = #selector(handleClick(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    @objc func handleClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(NSMenuItem(title: "显示仪表盘", action: #selector(showDashboard), keyEquivalent: ""))
            menu.addItem(NSMenuItem(title: "显示对话", action: #selector(showChat), keyEquivalent: ""))
            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
            for item in menu.items { item.target = self }
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            onToggle()
        }
    }

    @objc func showDashboard() { onToggle() }
    @objc func showChat() { onToggleChat() }
}

// MARK: - AppDelegate

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    let viewModel = StatsViewModel()
    let panelManager = PanelManager()

    var statusBarController: StatusBarController?
    var mainWindow: NSWindow?
    var hotkeyManager: HotkeyManager?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusBar()
        setupGlobalHotkey()
        showMainWindow()
        observeConversationPanel()
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
            window.orderOut(nil)
        } else {
            showMainWindow()
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
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let contentView = DashboardView(viewModel: viewModel)
            .environment(\.colorScheme, .dark)
            .frame(minWidth: 480, minHeight: 500)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 660),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "CC Stats"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.backgroundColor = NSColor(red: 0.102, green: 0.106, blue: 0.18, alpha: 1)
        panel.contentView = NSHostingView(rootView: contentView)
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true

        positionWindowBelowStatusBar(panel)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.mainWindow = panel
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
