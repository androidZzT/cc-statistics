import SwiftUI
import Combine
import Carbon.HIToolbox
import ServiceManagement

extension Notification.Name {
    static let islandDebugModeChanged = Notification.Name("ccstats.islandDebugModeChanged")
}

// MARK: - BridgeDaemonController

final class BridgeDaemonController {
    private var process: Process?
    private let host = "127.0.0.1"
    private let port = "8765"

    func startIfNeeded() {
        probeHealth { [weak self] healthy in
            guard let self, !healthy else { return }
            self.launch()
        }
    }

    func stop() {
        process?.terminate()
        process = nil
    }

    private func launch() {
        guard process == nil else { return }
        guard let executable = bridgeExecutablePath() else {
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = ["--host", host, "--port", port]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        proc.terminationHandler = { [weak self] _ in
            self?.process = nil
        }

        do {
            try proc.run()
            process = proc
        } catch {
            process = nil
        }
    }

    private func probeHealth(completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "http://\(host):\(port)/v1/health") else {
            completion(false)
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 0.25
        URLSession.shared.dataTask(with: request) { _, response, _ in
            let healthy = (response as? HTTPURLResponse)?.statusCode == 200
            completion(healthy)
        }.resume()
    }

    private func bridgeExecutablePath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            ProcessInfo.processInfo.environment["CC_STATS_BRIDGE_BIN"] ?? "",
            (home as NSString).appendingPathComponent(".local/bin/cc-stats-bridge"),
            "/opt/homebrew/bin/cc-stats-bridge",
            "/usr/local/bin/cc-stats-bridge",
        ]

        for candidate in candidates where !candidate.isEmpty {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}

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

    // Dedup: only re-render when display text actually changes
    private var renderedLine1: String = ""
    private var renderedLine2: String = ""
    private var renderedOverLimit: Bool = false

    private let logoImage: NSImage
    private let staticClawdIcon: NSImage
    private var currentIcon: NSImage?

    // MARK: - Animation State

    private var animationTimer: Timer?
    private var animationFrameIndex: Int = 0
    private(set) var activityState: SessionActivityState = .idle
    private let islandDebugModeKey = "cc_stats_island_debug_force"

    /// Clawd mascot image names for each animation frame per state.
    static let animationFrames: [SessionActivityState: [String]] = [
        .active: ["clawd-typing-f0", "clawd-typing-f1", "clawd-typing-f2"],
        .waitingApproval: ["clawd-thinking-f0", "clawd-thinking-f1"],
        .idle: ["clawd-idle-f0", "clawd-idle-f1"],
        .sleeping: ["clawd-sleeping-f0", "clawd-sleeping-f1", "clawd-sleeping-f2"],
    ]

    /// Frame interval per state (seconds).
    static let frameIntervals: [SessionActivityState: TimeInterval] = [
        .active: 0.15,
        .waitingApproval: 0.45,
        .idle: 0.6,
        .sleeping: 0.8,
    ]

    init(onToggle: @escaping () -> Void, onToggleChat: @escaping () -> Void) {
        self.onToggle = onToggle
        self.onToggleChat = onToggleChat
        self.logoImage = drawClaudeLogo(size: NSSize(width: 18, height: 18))
        self.staticClawdIcon = Self.loadStaticClawdStatusBarIcon() ?? logoImage
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let initialIcon = staticClawdIcon
        self.currentIcon = initialIcon
        print("[CCStats] init: initialIcon loaded=\(currentIcon != nil), isTemplate=\(currentIcon?.isTemplate ?? false)")

        if let button = statusItem.button {
            button.action = #selector(handleClick(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageOnly
            button.image = initialIcon
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
        let debugItem = NSMenuItem(
            title: "Island Debug Mode",
            action: #selector(toggleIslandDebugMode(_:)),
            keyEquivalent: ""
        )
        debugItem.target = self
        debugItem.state = isIslandDebugModeEnabled ? .on : .off
        menu.addItem(debugItem)

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
    @objc func toggleIslandDebugMode(_ sender: NSMenuItem) {
        let next = !isIslandDebugModeEnabled
        UserDefaults.standard.set(next, forKey: islandDebugModeKey)
        NotificationCenter.default.post(
            name: .islandDebugModeChanged,
            object: nil,
            userInfo: ["enabled": next]
        )
    }

    private var isIslandDebugModeEnabled: Bool {
        UserDefaults.standard.bool(forKey: islandDebugModeKey)
    }

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

        // 跳过未变化的渲染 — 避免触发 NSStatusItem replicant 更新
        guard line1 != renderedLine1 || line2 != renderedLine2 || isOverLimit != renderedOverLimit else { return }
        renderedLine1 = line1
        renderedLine2 = line2
        renderedOverLimit = isOverLimit

        let icon = currentIcon ?? logoImage

        // 无数据时仅显示图标
        if line1.isEmpty && line2.isEmpty {
            button.image = icon
            button.title = ""
            button.imagePosition = .imageOnly
            statusItem.length = NSStatusItem.variableLength
            return
        }

        // 合成图标+文字为单张 NSImage
        let textColor: NSColor = isOverLimit ? .systemRed : .white
        let compositeImage = renderStatusBarImage(icon: icon, line1: line1, line2: line2, textColor: textColor)
        button.image = compositeImage
        button.title = ""
        button.imagePosition = .imageOnly
        statusItem.length = NSStatusItem.variableLength
    }

    private func renderStatusBarImage(icon: NSImage, line1: String, line2: String, textColor: NSColor) -> NSImage {
        let barHeight: CGFloat = 22
        let leftMargin: CGFloat = 1
        let iconTextGap: CGFloat = 3
        let rightMargin: CGFloat = 4
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)

        let iconW = icon.size.width
        let iconH = icon.size.height

        // Measure text
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
        ]
        let line1Size = (line1 as NSString).size(withAttributes: attrs)
        let line2Size = line2.isEmpty ? NSSize.zero : (line2 as NSString).size(withAttributes: attrs)
        let textWidth = max(line1Size.width, line2Size.width)

        let totalWidth = leftMargin + iconW + iconTextGap + textWidth + rightMargin
        let logicalSize = NSSize(width: totalWidth, height: barHeight)

        // Use backing scale factor for Retina-aware rendering
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let pixelW = Int(totalWidth * scale)
        let pixelH = Int(barHeight * scale)

        guard let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelW,
            pixelsHigh: pixelH,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            // Fallback: return icon as-is
            return icon
        }
        bitmapRep.size = logicalSize

        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: bitmapRep)
        NSGraphicsContext.current = context

        // Standard macOS coordinates: y=0 at bottom, no transforms needed

        // Draw icon vertically centered
        let iconY = (barHeight - iconH) / 2
        icon.draw(in: NSRect(x: leftMargin, y: iconY, width: iconW, height: iconH),
                  from: .zero, operation: .sourceOver, fraction: 1.0)

        // Right-align text
        let rightEdge = totalWidth - rightMargin
        let lineSpacing: CGFloat = 1

        if line2.isEmpty {
            // Single line: vertically centered
            let x1 = rightEdge - line1Size.width
            let textY = (barHeight - line1Size.height) / 2
            (line1 as NSString).draw(at: NSPoint(x: x1, y: textY), withAttributes: attrs)
        } else {
            // Two lines: vertically centered as a block
            let line1H = line1Size.height
            let line2H = line2Size.height
            let totalTextH = line1H + lineSpacing + line2H
            let baseY = (barHeight - totalTextH) / 2
            let x1 = rightEdge - line1Size.width
            let x2 = rightEdge - line2Size.width
            // y=0 at bottom: line2 at baseY (bottom), line1 above it
            (line2 as NSString).draw(at: NSPoint(x: x2, y: baseY), withAttributes: attrs)
            (line1 as NSString).draw(at: NSPoint(x: x1, y: baseY + line2H + lineSpacing), withAttributes: attrs)
        }

        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: logicalSize)
        image.addRepresentation(bitmapRep)
        image.isTemplate = false
        return image
    }

    private static func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000_000 { return String(format: "%.1fB", Double(n) / 1e9) }
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1e6) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1e3) }
        return "\(n)"
    }

    // MARK: - Clawd Image Loading

    /// Fixed icon canvas size — all frames are scaled to fit within this box
    /// and drawn centered to prevent status bar jitter during animation.
    static let iconCanvasSize = NSSize(width: 30, height: 18)
    static let staticStatusBarIconSize = NSSize(width: 20, height: 12)

    private static func loadClawdRawImage(frameName: String) -> NSImage? {
        var rawImage: NSImage?

        let resourcesDir = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/clawd")
            .path
        let imagePath2x = "\(resourcesDir)/\(frameName)@2x.png"
        let imagePath1x = "\(resourcesDir)/\(frameName).png"

        if FileManager.default.fileExists(atPath: imagePath2x) {
            rawImage = NSImage(contentsOfFile: imagePath2x)
        } else if FileManager.default.fileExists(atPath: imagePath1x) {
            rawImage = NSImage(contentsOfFile: imagePath1x)
        }

        if rawImage == nil {
            let swiftDir = URL(fileURLWithPath: #file).deletingLastPathComponent().path
            let devPath2x = "\(swiftDir)/Resources/clawd/\(frameName)@2x.png"
            let devPath1x = "\(swiftDir)/Resources/clawd/\(frameName).png"
            if FileManager.default.fileExists(atPath: devPath2x) {
                rawImage = NSImage(contentsOfFile: devPath2x)
            } else if FileManager.default.fileExists(atPath: devPath1x) {
                rawImage = NSImage(contentsOfFile: devPath1x)
            }
        }

        return rawImage
    }

    /// Load a Clawd mascot image by frame name.
    /// Search order: bundle Resources/clawd/ → dev source directory → nil.
    /// All images are normalized to a fixed canvas size to prevent layout jitter.
    static func loadClawdImage(frameName: String) -> NSImage? {
        guard let raw = loadClawdRawImage(frameName: frameName) else { return nil }

        // Scale to fit within canvas, preserving aspect ratio
        let rawRatio = raw.size.width / raw.size.height
        let canvasRatio = iconCanvasSize.width / iconCanvasSize.height
        let scaledW: CGFloat
        let scaledH: CGFloat
        if rawRatio > canvasRatio {
            // Wider than canvas — fit by width
            scaledW = iconCanvasSize.width
            scaledH = scaledW / rawRatio
        } else {
            // Taller or same — fit by height
            scaledH = iconCanvasSize.height
            scaledW = scaledH * rawRatio
        }

        // Draw centered on fixed-size canvas to prevent jitter
        let canvas = NSImage(size: iconCanvasSize, flipped: false) { rect in
            let x = (rect.width - scaledW) / 2
            let y = (rect.height - scaledH) / 2
            raw.draw(in: NSRect(x: x, y: y, width: scaledW, height: scaledH),
                     from: .zero, operation: .sourceOver, fraction: 1.0)
            return true
        }
        canvas.isTemplate = false
        return canvas
    }

    static func loadStaticClawdStatusBarIcon() -> NSImage? {
        let candidateNames = [
            "clawd-status-static@2x.png",
            "clawd-status-static.png",
        ]

        let searchDirs = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/clawd").path,
            "\(URL(fileURLWithPath: #file).deletingLastPathComponent().path)/Resources/clawd",
        ]

        for directory in searchDirs {
            for name in candidateNames {
                let path = "\(directory)/\(name)"
                if FileManager.default.fileExists(atPath: path),
                   let image = NSImage(contentsOfFile: path) {
                    image.size = staticStatusBarIconSize
                    image.isTemplate = false
                    return image
                }
            }
        }

        return loadClawdImage(frameName: "clawd-idle-f0")
    }

    // MARK: - Activity State Animation

    func updateActivityState(_ state: SessionActivityState) {
        print("[CCStats] updateActivityState called: \(state)")
        guard state != activityState else { return }
        activityState = state
        stopAnimation()
        applyActivityIcon()
    }

    func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    private func advanceAnimationFrame() {
        applyActivityIcon()
    }

    private func applyActivityIcon() {
        guard let button = statusItem.button else { return }
        let image = staticClawdIcon
        print("[CCStats] applyActivityIcon: state=\(activityState) source=static-clawd imageNil=\(false)")

        button.contentTintColor = nil

        // Store icon for refreshLabel to use later
        currentIcon = image

        // Directly update button image — bypasses refreshLabel dedup guard
        // so icon changes always take effect even when text hasn't changed.
        let icon = currentIcon ?? logoImage
        if renderedLine1.isEmpty && renderedLine2.isEmpty {
            button.image = icon
            button.imagePosition = .imageOnly
        } else {
            let textColor: NSColor = isOverLimit ? .systemRed : .white
            let compositeImage = renderStatusBarImage(icon: icon, line1: renderedLine1, line2: renderedLine2, textColor: textColor)
            button.image = compositeImage
            button.imagePosition = .imageOnly
        }
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
    private let notificationServer = NotificationServer()
    private let bridgeDaemonController = BridgeDaemonController()
    private let activityMonitor = SessionActivityMonitor()
    private let islandOverlayController = IslandOverlayController()
    private var lastActivitySnapshot: SessionActivitySnapshot?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if handleSnapshotRenderRequestIfNeeded() {
            return
        }

        // Initialize notification system (requests authorization + sets delegate)
        NotificationManager.shared.requestAuthorization()

        // Start local HTTP server so Python hooks can send native notifications
        notificationServer.start()
        bridgeDaemonController.startIfNeeded()

        setupStatusBar()
        setupGlobalHotkey()
        setupActivityMonitor()
        observeIslandDebugMode()
        observeConversationPanel()
        observeTokenUsage()
        observeTheme()
    }

    private func handleSnapshotRenderRequestIfNeeded() -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard let outputPath = env["CC_STATS_RENDER_ISLAND_SNAPSHOT_PATH"], !outputPath.isEmpty else {
            return false
        }

        let mode = IslandSnapshotRenderer.PreviewMode(
            rawValue: env["CC_STATS_RENDER_ISLAND_SNAPSHOT_MODE"] ?? ""
        ) ?? .expandedApproval

        do {
            try IslandSnapshotRenderer.renderPreview(to: outputPath, mode: mode)
            print("[CCStats] Rendered island snapshot to \(outputPath)")
        } catch {
            fputs("[CCStats] Failed to render island snapshot: \(error)\n", stderr)
        }

        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        activityMonitor.stop()
        bridgeDaemonController.stop()
        statusBarController?.stopAnimation()
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

    // MARK: - Activity Monitor

    private func setupActivityMonitor() {
        print("[CCStats] setupActivityMonitor called")
        islandOverlayController.setDebugMode(currentIslandDebugMode())
        islandOverlayController.onOpenDashboard = { [weak self] in
            self?.showMainWindow()
        }
        islandOverlayController.onOpenChat = { [weak self] in
            self?.openConversationPanel()
        }
        islandOverlayController.onOpenTerminal = {
            NotificationManager.shared.focusTerminal()
        }
        activityMonitor.onStateChange = { [weak self] state in
            print("[CCStats] onStateChange: \(state)")
            DispatchQueue.main.async {
                self?.statusBarController?.updateActivityState(state)
            }
        }
        activityMonitor.onSnapshotChange = { [weak self] snapshot in
            DispatchQueue.main.async {
                self?.lastActivitySnapshot = snapshot
                self?.islandOverlayController.update(with: snapshot)
            }
        }
        activityMonitor.start()
    }

    private func observeIslandDebugMode() {
        NotificationCenter.default.publisher(for: .islandDebugModeChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self else { return }
                let enabled = (notification.userInfo?["enabled"] as? Bool) ?? self.currentIslandDebugMode()
                self.islandOverlayController.setDebugMode(enabled)
                if let snapshot = self.lastActivitySnapshot {
                    self.islandOverlayController.update(with: snapshot)
                }
            }
            .store(in: &cancellables)
    }

    private func currentIslandDebugMode() -> Bool {
        let fromDefaults = UserDefaults.standard.bool(forKey: "cc_stats_island_debug_force")
        let fromEnv = ProcessInfo.processInfo.environment["CC_STATS_ISLAND_DEBUG_FORCE"] == "1"
        let fromFlagFile = FileManager.default.fileExists(atPath: (NSHomeDirectory() as NSString).appendingPathComponent(".cc-stats/island-debug-force"))
        return fromDefaults || fromEnv || fromFlagFile
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

    private func openConversationPanel() {
        showMainWindow()
        guard !viewModel.showConversationPanel else { return }
        viewModel.toggleConversationPanel()
    }

    private func hideMainWindowAnimated() {
        guard let window = mainWindow else { return }
        viewModel.isPanelVisible = false
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
        viewModel.isPanelVisible = true
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
            styleMask: [.titled, .fullSizeContentView],
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
        panel.level = .normal
        panel.hidesOnDeactivate = true
        panel.isFloatingPanel = false
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
        print("[CCStats] applyThemeToPanel: theme=\(theme)")
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
                print("[CCStats] observeTheme sink: theme=\(theme), mainWindow=\(self.mainWindow != nil)")

                // 设置 NSApp.appearance（影响全局 + 所有未显式设置 appearance 的 window）
                switch theme {
                case "dark":
                    NSApp.appearance = NSAppearance(named: .darkAqua)
                case "light":
                    NSApp.appearance = NSAppearance(named: .aqua)
                default:  // "auto" — 跟随系统
                    NSApp.appearance = nil
                }

                // 同时更新各个 panel
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
                            viewModel: self.viewModel,
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
