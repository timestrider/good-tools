//  Good-tools · 浏览器：多 UA 一键切换 + 收藏夹（源自 GoodBrowser）

import Cocoa
import WebKit

// MARK: - UA 预设

struct UAPreset {
    let title: String
    let ua: String?
}

let kPresets: [UAPreset] = [
    UAPreset(title: "系统默认 (macOS Safari)", ua: nil),
    UAPreset(title: "Windows · Chrome 131",
             ua: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"),
    UAPreset(title: "Windows · Edge 131",
             ua: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36 Edg/131.0.0.0"),
    UAPreset(title: "Windows · Firefox 133",
             ua: "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:133.0) Gecko/20100101 Firefox/133.0"),
    UAPreset(title: "macOS · Chrome 131",
             ua: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"),
    UAPreset(title: "iPhone · Safari 18",
             ua: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"),
    UAPreset(title: "iPhone · Chrome 131",
             ua: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/131.0.6778.73 Mobile/15E148 Safari/604.1"),
    UAPreset(title: "iPad · Safari 18",
             ua: "Mozilla/5.0 (iPad; CPU OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"),
    UAPreset(title: "Android · Chrome 131",
             ua: "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36"),
    UAPreset(title: "微信 · iOS 内置",
             ua: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 MicroMessenger/8.0.50(0x1800322c) NetType/WIFI Language/zh_CN"),
    UAPreset(title: "百度 · Baiduspider",
             ua: "Mozilla/5.0 (compatible; Baiduspider/2.0; +http://www.baidu.com/search/spider.html)"),
    UAPreset(title: "Google · Googlebot",
             ua: "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; Googlebot/2.1; +http://www.google.com/bot.html) Chrome/131.0.0.0 Safari/537.36"),
]

let kCustomIndex = kPresets.count
let kHomeURL = URL(string: "https://www.baidu.com")!

// MARK: - 收藏

struct Bookmark: Codable {
    var title: String
    var url: String
}

final class BookmarkStore {
    static let shared = BookmarkStore()
    private let key = "bookmarks.v1"
    private(set) var items: [Bookmark] = []

    init() { load() }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let arr = try? JSONDecoder().decode([Bookmark].self, from: data) else { return }
        items = arr
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func contains(_ url: String) -> Bool { items.contains { $0.url == url } }

    /// 返回 true 表示已加入收藏，false 表示已移除
    @discardableResult
    func toggle(title: String, url: String) -> Bool {
        if let i = items.firstIndex(where: { $0.url == url }) {
            items.remove(at: i)
            save()
            return false
        }
        items.insert(Bookmark(title: title, url: url), at: 0)
        save()
        return true
    }

    func remove(url: String) {
        items.removeAll { $0.url == url }
        save()
    }
}

// MARK: - 细进度条

final class ProgressLine: NSView {
    var progress: Double = 0 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard progress > 0 else { return }
        NSColor.tertiaryLabelColor.withAlphaComponent(0.85).setFill()
        let w = bounds.width * CGFloat(min(max(progress, 0), 1))
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: w, height: bounds.height)).fill()
    }
}

// MARK: - 主视图

final class BrowserViewController: NSViewController {

    private var webView: WKWebView!
    private var addressField: NSTextField!
    private var uaPopUp: NSPopUpButton!
    private var backButton: NSButton!
    private var forwardButton: NSButton!
    private var reloadButton: NSButton!
    private var starButton: NSButton!
    private var bookmarksButton: NSButton!
    private var progressLine: ProgressLine!

    private var observations: [NSKeyValueObservation] = []
    private var currentUA: String?

    // MARK: 构建界面

    override func loadView() {
        let root = NSView()

        // 顶部栏
        let bar = NSVisualEffectView()
        bar.material = .headerView
        bar.blendingMode = .withinWindow
        bar.state = .active
        bar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(bar)

        backButton = makeSymbolButton("chevron.left", action: #selector(goBackAction), tooltip: "后退 (⌘[)")
        forwardButton = makeSymbolButton("chevron.right", action: #selector(goForwardAction), tooltip: "前进 (⌘])")
        reloadButton = makeSymbolButton("arrow.clockwise", action: #selector(reloadAction), tooltip: "刷新 (⌘R)")
        starButton = makeSymbolButton("star", action: #selector(toggleBookmarkAction), tooltip: "收藏 / 取消收藏 (⌘D)")
        bookmarksButton = makeSymbolButton("text.book.closed", action: #selector(showBookmarksMenu(_:)), tooltip: "收藏夹")
        backButton.isEnabled = false
        forwardButton.isEnabled = false

        addressField = NSTextField()
        addressField.placeholderString = "输入网址或搜索内容"
        addressField.font = .systemFont(ofSize: 13)
        addressField.isBezeled = true
        addressField.bezelStyle = .roundedBezel
        addressField.focusRingType = .none
        addressField.lineBreakMode = .byTruncatingTail
        addressField.cell?.wraps = false
        addressField.cell?.isScrollable = true
        addressField.target = self
        addressField.action = #selector(loadFromAddressBar)
        addressField.translatesAutoresizingMaskIntoConstraints = false
        addressField.heightAnchor.constraint(equalToConstant: 24).isActive = true
        addressField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addressField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        uaPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
        uaPopUp.addItems(withTitles: kPresets.map { $0.title } + ["自定义 UA…"])
        uaPopUp.target = self
        uaPopUp.action = #selector(uaSelectionChanged(_:))
        uaPopUp.font = .systemFont(ofSize: 11)
        uaPopUp.translatesAutoresizingMaskIntoConstraints = false
        uaPopUp.widthAnchor.constraint(equalToConstant: 208).isActive = true

        let stack = NSStackView(views: [backButton, forwardButton, reloadButton, addressField,
                                        starButton, bookmarksButton, uaPopUp])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)

        progressLine = ProgressLine()
        progressLine.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(progressLine)

        // WebView
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        cfg.preferences.isElementFullscreenEnabled = true
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: cfg)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(webView)

        // 工具栏底部分隔线
        let hairline = NSView()
        hairline.wantsLayer = true
        hairline.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
        hairline.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(hairline)

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 46),

            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: bar.centerYAnchor, constant: -1),

            progressLine.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            progressLine.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            progressLine.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            progressLine.heightAnchor.constraint(equalToConstant: 3),

            webView.topAnchor.constraint(equalTo: bar.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            hairline.topAnchor.constraint(equalTo: bar.bottomAnchor),
            hairline.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1),
        ])

        view = root
        bindObservers()
    }

    func start() {
        restorePreferences()
        webView.load(URLRequest(url: kHomeURL))
        DispatchQueue.main.async { [weak self] in
            guard let self, let w = self.view.window else { return }
            w.makeFirstResponder(self.webView)
        }
    }

    /// 窗口重新打开时把焦点还给页面，地址栏不该抢焦点
    func focusPage() {
        guard let w = view.window else { return }
        w.makeFirstResponder(webView)
    }

    /// 关窗只是收起来，页面还在。让里面的音视频停下，别在后台偷偷播。
    func suspendMedia() {
        webView.evaluateJavaScript(
            "document.querySelectorAll('video,audio').forEach(function(e){ try { e.pause() } catch (x) {} })",
            completionHandler: nil)
    }

    private func makeSymbolButton(_ symbol: String, action: Selector, tooltip: String) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) ?? NSImage()
        let b = NSButton(image: image, target: self, action: action)
        b.bezelStyle = .regularSquare
        b.isBordered = false
        b.imagePosition = .imageOnly
        b.contentTintColor = .secondaryLabelColor
        b.toolTip = tooltip
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 28).isActive = true
        b.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return b
    }

    // MARK: 状态绑定

    private func bindObservers() {
        observations.append(webView.observe(\.estimatedProgress) { [weak self] wv, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let p = wv.estimatedProgress
                self.progressLine.progress = p
                self.progressLine.isHidden = p >= 0.999
            }
        })
        observations.append(webView.observe(\.url) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.syncAddressField()
                self?.updateStarButton()
            }
        })
        observations.append(webView.observe(\.title) { [weak self] wv, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let t = wv.title ?? ""
                self.view.window?.title = t.isEmpty ? "Good-tools" : t
            }
        })
        observations.append(webView.observe(\.canGoBack) { [weak self] wv, _ in
            DispatchQueue.main.async { self?.backButton.isEnabled = wv.canGoBack }
        })
        observations.append(webView.observe(\.canGoForward) { [weak self] wv, _ in
            DispatchQueue.main.async { self?.forwardButton.isEnabled = wv.canGoForward }
        })
        observations.append(webView.observe(\.isLoading) { [weak self] wv, _ in
            DispatchQueue.main.async { self?.updateReloadButton(loading: wv.isLoading) }
        })
    }

    private func updateReloadButton(loading: Bool) {
        let symbol = loading ? "xmark" : "arrow.clockwise"
        reloadButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage()
        reloadButton.toolTip = loading ? "停止 (⌘.)" : "刷新 (⌘R)"
    }

    private func syncAddressField() {
        // 用户正在编辑地址栏时不要覆盖
        if let fr = view.window?.firstResponder as? NSTextView, fr.delegate === addressField { return }
        addressField.stringValue = webView.url?.absoluteString ?? ""
    }

    private func updateStarButton() {
        let marked = webView.url.map { BookmarkStore.shared.contains($0.absoluteString) } ?? false
        let symbol = marked ? "star.fill" : "star"
        starButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage()
        // 灰阶区分：已收藏 = 深灰实心，未收藏 = 浅灰空心
        starButton.contentTintColor = marked ? .labelColor : .tertiaryLabelColor
    }

    // MARK: 导航

    @objc func loadFromAddressBar() {
        guard let url = Self.normalize(addressField.stringValue) else { return }
        webView.load(URLRequest(url: url))
        view.window?.makeFirstResponder(webView)
    }

    static func normalize(_ input: String) -> URL? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let u = URL(string: s), let scheme = u.scheme, !scheme.isEmpty, u.host != nil {
            return u
        }
        let looksLikeHost = !s.contains(" ") && (s.contains(".") || s.hasPrefix("localhost") || s.contains(":"))
        if looksLikeHost {
            let local = s.hasPrefix("localhost") || s.hasPrefix("127.") || s.hasPrefix("192.168.")
            return URL(string: (local ? "http://" : "https://") + s)
        }
        let q = s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
        return URL(string: "https://www.baidu.com/s?wd=" + q)
    }

    @objc func goBackAction() { if webView.canGoBack { webView.goBack() } }
    @objc func goForwardAction() { if webView.canGoForward { webView.goForward() } }

    @objc func reloadAction() {
        if webView.isLoading {
            webView.stopLoading()
        } else if webView.url != nil {
            var req = URLRequest(url: webView.url!)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            webView.load(req)
        } else {
            webView.load(URLRequest(url: kHomeURL))
        }
    }

    @objc func focusAddressBar() {
        view.window?.makeFirstResponder(addressField)
        addressField.currentEditor()?.selectAll(nil)
    }

    @objc func zoomIn() { webView.pageZoom = min(webView.pageZoom + 0.1, 3.0) }
    @objc func zoomOut() { webView.pageZoom = max(webView.pageZoom - 0.1, 0.4) }
    @objc func zoomReset() { webView.pageZoom = 1.0 }

    @objc func showCurrentUA() {
        webView.evaluateJavaScript("navigator.userAgent") { value, _ in
            let jsUA = (value as? String) ?? "未知"
            let alert = NSAlert()
            alert.messageText = "当前页面看到的 User-Agent"
            let enabled = self.currentUA ?? "系统默认"
            alert.informativeText = "已下发 UA：\n\(enabled)\n\n页面 JS 读到：\n\(jsUA)"
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
    }

    // MARK: UA

    private func restorePreferences() {
        let d = UserDefaults.standard
        if d.bool(forKey: "isCustomUA"), let c = d.string(forKey: "customUA"), !c.isEmpty {
            currentUA = c
            uaPopUp.selectItem(at: kCustomIndex)
        } else {
            let idx = min(max(d.integer(forKey: "presetIndex"), 0), kPresets.count - 1)
            currentUA = kPresets[idx].ua
            uaPopUp.selectItem(at: idx)
        }
        webView.customUserAgent = currentUA
        uaPopUp.toolTip = currentUA ?? "系统默认"
    }

    @objc private func uaSelectionChanged(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem
        if idx >= 0 && idx < kPresets.count {
            UserDefaults.standard.set(true, forKey: "isPreset")
            UserDefaults.standard.set(false, forKey: "isCustomUA")
            UserDefaults.standard.set(idx, forKey: "presetIndex")
            applyUA(kPresets[idx].ua, reload: true)
        } else {
            promptCustomUA()
        }
    }

    private func promptCustomUA() {
        let alert = NSAlert()
        alert.messageText = "自定义 User-Agent"
        alert.informativeText = "留空则恢复系统默认 UA。"
        alert.addButton(withTitle: "应用")
        alert.addButton(withTitle: "取消")
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 560, height: 24))
        tf.stringValue = currentUA ?? ""
        tf.placeholderString = "Mozilla/5.0 ..."
        alert.accessoryView = tf
        alert.window.initialFirstResponder = tf
        if alert.runModal() == .alertFirstButtonReturn {
            let v = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(v, forKey: "customUA")
            UserDefaults.standard.set(!v.isEmpty, forKey: "isCustomUA")
            uaPopUp.selectItem(at: kCustomIndex)
            applyUA(v.isEmpty ? nil : v, reload: true)
        } else {
            restorePreferences()
        }
    }

    /// 应用 UA 并强制重新请求，确保服务端拿到的是新 UA
    private func applyUA(_ ua: String?, reload: Bool) {
        currentUA = ua
        webView.customUserAgent = ua
        uaPopUp.toolTip = ua ?? "系统默认"
        guard reload else { return }
        if let url = webView.url, url.absoluteString != "about:blank" {
            var req = URLRequest(url: url)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            webView.load(req)
        } else {
            webView.load(URLRequest(url: kHomeURL))
        }
    }

    // MARK: 收藏

    @objc func toggleBookmarkAction() {
        guard let url = webView.url?.absoluteString, url != "about:blank" else {
            NSSound.beep()
            return
        }
        let title = (webView.title?.isEmpty == false ? webView.title! : (webView.url?.host ?? url))
        let added = BookmarkStore.shared.toggle(title: title, url: url)
        updateStarButton()
        if added {
            NSSound(named: "Pop")?.play()
        }
    }

    @objc private func showBookmarksMenu(_ sender: NSButton) {
        let menu = NSMenu()
        let items = BookmarkStore.shared.items

        if items.isEmpty {
            let empty = NSMenuItem(title: "暂无收藏（⌘D 收藏当前页）", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for bm in items {
                let item = NSMenuItem(title: bm.title.isEmpty ? bm.url : bm.title,
                                      action: #selector(openBookmark(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = bm.url
                item.toolTip = bm.url
                item.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
                menu.addItem(item)
            }
        }

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: sender)
    }

    @objc private func openBookmark(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String, let url = URL(string: s) else { return }
        webView.load(URLRequest(url: url))
    }
}

// MARK: - WKNavigationDelegate

extension BrowserViewController: WKNavigationDelegate {

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(),
           !["http", "https", "about", "file", "data", "blob", "javascript", "ws", "wss"].contains(scheme) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        updateStarButton()
        syncAddressField()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        progressLine.isHidden = true
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        progressLine.isHidden = true
    }
}

// MARK: - WKUIDelegate

extension BrowserViewController: WKUIDelegate {

    /// target=_blank 在当前视图打开
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: view.window!) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: view.window!) { resp in
            completionHandler(resp == .alertFirstButtonReturn)
        }
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = prompt
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 400, height: 24))
        tf.stringValue = defaultText ?? ""
        alert.accessoryView = tf
        alert.beginSheetModal(for: view.window!) { resp in
            completionHandler(resp == .alertFirstButtonReturn ? tf.stringValue : nil)
        }
    }
}
