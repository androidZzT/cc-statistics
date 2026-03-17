import Cocoa
import WebKit

// ── Claude Logo 像素位图 (从 Unicode block art 映射) ──
// ▐▛███▜▌
// ▝▜█████▛▘
//   ▘▘ ▝▝
let claudeBitmap: [[Int]] = [
    [0,0,0,1,1,1,1,1,1,1,1,1,1,1,1,0,0,0],
    [0,0,0,1,1,0,1,1,1,1,1,1,0,1,1,0,0,0],
    [0,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,0],
    [0,0,0,1,1,1,1,1,1,1,1,1,1,1,1,0,0,0],
    [0,0,0,0,1,0,1,0,0,0,0,1,0,1,0,0,0,0],
]

func drawClaudeLogo(size: NSSize) -> NSImage {
    let image = NSImage(size: size, flipped: true) { rect in
        let cols = claudeBitmap[0].count  // 18
        let rows = claudeBitmap.count     // 5

        // 终端字符宽高比约 1:2
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
    image.isTemplate = true  // 跟随系统亮/暗配色
    return image
}

// ── Token 格式化 ──
func formatTokens(_ n: Int) -> String {
    if n >= 1_000_000_000 { return String(format: "%.1fB", Double(n) / 1e9) }
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1e6) }
    if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1e3) }
    return "\(n)"
}

// ── App Delegate ──
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var webView: WKWebView!
    var port: Int = 19827
    var eventMonitor: Any?
    var refreshTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if args.count > 1, let p = Int(args[1]) {
            port = p
        }

        // WebView
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 960, height: 680), configuration: config)
        webView.setValue(false, forKey: "drawsBackground")

        // ViewController
        let vc = NSViewController()
        vc.view = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 680))
        vc.view.addSubview(webView)
        webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: vc.view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: vc.view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor),
        ])

        // Popover
        popover = NSPopover()
        popover.contentSize = NSSize(width: 960, height: 680)
        popover.behavior = .transient
        popover.contentViewController = vc
        popover.setValue(true, forKey: "shouldHideAnchor")
        popover.appearance = NSAppearance(named: .darkAqua)

        // 状态栏 — 固定宽度以容纳 icon + token 文字
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.action = #selector(togglePopover(_:))
            button.target = self

            // 设置静态 icon（22x22），template 模式跟随系统配色
            let icon = drawClaudeLogo(size: NSSize(width: 22, height: 22))
            button.image = icon
            button.imagePosition = .imageLeading

            // 初始文字 — 不设 foregroundColor，让系统自动匹配 icon 颜色
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.title = " …"
        }

        // 加载页面
        if let url = URL(string: "http://127.0.0.1:\(port)/") {
            webView.load(URLRequest(url: url))
        }

        // 点击外部关闭
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            if let self = self, self.popover.isShown {
                self.popover.performClose(nil)
            }
        }

        // 首次加载 token 用量
        fetchTokenTotal()

        // 每 30 秒刷新 token 用量，实时跟踪当日消耗
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.fetchTokenTotal()
        }
        RunLoop.main.add(refreshTimer!, forMode: .common)
    }

    func fetchTokenTotal() {
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/stats?days=1") else { return }
        let task = URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let self = self, let data = data, error == nil else { return }
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let tokenUsage = json["token_usage"] as? [String: Any],
                   let total = tokenUsage["total"] as? Int {
                    DispatchQueue.main.async {
                        self.updateTokenLabel(total)
                    }
                }
            } catch {}
        }
        task.resume()
    }

    func updateTokenLabel(_ total: Int) {
        guard let button = statusItem.button else { return }
        button.title = " \(formatTokens(total))"
    }

    @objc func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            webView.evaluateJavaScript("if(typeof loadStats==='function')loadStats()", completionHandler: nil)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

// ── Main ──
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
