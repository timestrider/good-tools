//  Good-tools · 截图（⌃⌘A）

import Cocoa
import Carbon.HIToolbox
import ScreenCaptureKit

// MARK: - 截图（⌃⌘A）
//
// 流程：抓一次全屏 → 每块屏盖一层覆盖窗（显示的正是刚才那张图）→ 拖动框选 → 松开即复制。
// 抓屏用 ScreenCaptureKit 的 SCScreenshotManager，不用已废弃的 CGWindowListCreateImage：
// 后者在新系统上没权限时会安静地返回黑图/空图，排查起来很难受。
// 热键用 Carbon 的 RegisterEventHotKey：不需要「辅助功能」权限（全局事件监听才需要）。

/// 本进程里**要留在截图画面中**的自建窗口（现在只有浏览器）。
/// 抓屏时会整体排除自己的 app（否则菜单栏图标、设定窗入镜），排除后按 window id 把它放回来；
/// 覆盖层自己永远不会进这个集合，所以不会被拍进去。
enum OwnedWindows {
    static var browser: Set<CGWindowID> = []
}

/// 截图状态机：空闲 → 抓屏 → 覆盖层 → 选完复制 → 拆窗口。
final class SnapshotController {
    static let shared = SnapshotController()

    private var windows: [SnapshotWindow] = []
    private var isCapturing = false
    private var previousApp: NSRunningApplication?

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// 第一次调用会弹系统授权框；已经被拒过就不会再弹，只能去系统设置里勾。
    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    // MARK: 触发

    func trigger() {
        if isCapturing {          // 截图中再按一次 = 取消
            cancel()
            return
        }
        guard Self.hasPermission else {
            showPermissionPrompt()
            return
        }
        isCapturing = true
        previousApp = NSWorkspace.shared.frontmostApplication
        NSApp.activate(ignoringOtherApps: true)

        Task {
            do {
                let shots = try await Self.captureAllDisplays()
                await MainActor.run {
                    guard self.isCapturing else { return }
                    if shots.images.isEmpty {
                        self.isCapturing = false
                        self.reportFailure("没有抓到任何屏幕。")
                    } else {
                        self.present(shots)
                    }
                }
            } catch {
                await MainActor.run {
                    self.isCapturing = false
                    self.reportFailure("抓屏失败：\(error.localizedDescription)\n\n"
                                       + "多半是「屏幕录制」权限没给。")
                }
            }
        }
    }

    private func present(_ shots: SnapshotController.CaptureResult) {
        var created: [SnapshotWindow] = []
        for screen in NSScreen.screens {
            guard let id = screen.displayID, let image = shots.images[id] else { continue }
            let frames = Self.windowRects(on: screen, from: shots.windows)
            created.append(SnapshotWindow(screen: screen, image: image,
                                          windowRects: frames, controller: self))
        }
        // displayID 对不上（极少见）时退化成主屏一张
        if created.isEmpty, let screen = NSScreen.main, let image = shots.images.values.first {
            let frames = Self.windowRects(on: screen, from: shots.windows)
            created.append(SnapshotWindow(screen: screen, image: image,
                                          windowRects: frames, controller: self))
        }
        windows = created

        NSApp.activate(ignoringOtherApps: true)
        let mouse = NSEvent.mouseLocation
        let target = created.first { $0.frame.contains(mouse) } ?? created.first
        for window in created {
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(window.contentView)
        }
        target?.makeKey()
    }

    /// 把窗口几何从 CG 全局坐标（原点主屏左上、y 向下）换成某块屏的视图坐标（原点该屏左下）。
    /// 只留和这块屏相交的部分；顺序保持 front-to-back，第一个命中的就是最上层窗口。
    static func windowRects(on screen: NSScreen, from frames: [WindowFrame]) -> [NSRect] {
        let primaryHeight = NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height
            ?? NSScreen.screens.first?.frame.height ?? 0
        let bounds = NSRect(origin: .zero, size: screen.frame.size)

        return frames.compactMap { frame in
            let flipped = NSRect(x: frame.rect.minX,
                                 y: primaryHeight - frame.rect.maxY,
                                 width: frame.rect.width,
                                 height: frame.rect.height)
            let local = NSRect(x: flipped.minX - screen.frame.minX,
                               y: flipped.minY - screen.frame.minY,
                               width: flipped.width,
                               height: flipped.height)
            let clipped = local.intersection(bounds)
            return (clipped.isNull || clipped.width < 8 || clipped.height < 8) ? nil : clipped
        }
    }

    // MARK: 结束

    func finish(image: CGImage, pointSize: NSSize) {
        let nsImage = NSImage(cgImage: image, size: pointSize)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([nsImage])

        if UserDefaults.standard.bool(forKey: "snapshotSound") {
            NSSound(named: "Tink")?.play()
        }
        teardown()
    }

    func cancel() { teardown() }

    private func teardown() {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        isCapturing = false
        // 把焦点还给按下快捷键之前那个 app，接着粘贴才顺手
        if let previous = previousApp,
           previous.bundleIdentifier != Bundle.main.bundleIdentifier {
            previous.activate()
        }
        previousApp = nil
    }

    // MARK: 提示

    private func reportFailure(_ text: String) {
        NSSound.beep()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "截图失败"
        alert.informativeText = text
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func showPermissionPrompt() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "需要「屏幕录制」权限"
        alert.informativeText = """
        系统设置 → 隐私与安全性 → 屏幕录制，把 Good-tools 打开。
        如果它本来就在列表里，先关掉再重新打开一次（app 重新签名后旧授权会失效），然后重启 Good-tools。
        """
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "现在申请")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn: Self.openScreenRecordingSettings()
        case .alertSecondButtonReturn: _ = Self.requestPermission()
        default: break
        }
    }

    static func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            ?? URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension")!
        NSWorkspace.shared.open(url)
    }

    // MARK: 抓屏

    /// 一个 on-screen 窗口的位置（CG 全局坐标）与归属，用于「吸附到窗口」
    struct WindowFrame {
        var rect: CGRect
        var owner: String
    }

    struct CaptureResult {
        var images: [CGDirectDisplayID: CGImage]
        var windows: [WindowFrame]      // front-to-back 顺序
    }

    static func captureAllDisplays() async throws -> CaptureResult {
        let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                          onScreenWindowsOnly: true)
        // 把自己排除掉，否则菜单栏图标（以及万一开着的设定窗）会被拍进去
        let ownID = Bundle.main.bundleIdentifier
        let ownApps = content.applications.filter { $0.bundleIdentifier == ownID }
        // ……但浏览器窗口得放回来：截自己网页的内容是正经需求
        let ownBrowser = content.windows.filter {
            OwnedWindows.browser.contains(CGWindowID($0.windowID))
        }

        var images: [CGDirectDisplayID: CGImage] = [:]
        for display in content.displays {
            let filter = SCContentFilter(display: display,
                                         excludingApplications: ownApps,
                                         exceptingWindows: ownBrowser)
            let config = SCStreamConfiguration()
            // 坑：SCDisplay.width/height 是**点**（头文件写明 "in points"），不是像素。
            // 直接拿来当 config 尺寸，5K 屏（5120×2880，UI 2560×1440）会按 2560×1440 抓 ——
            // 等于降采样一半，截出来就是糊的。像素尺寸得用 CGDisplayPixelsWide/High。
            config.width = CGDisplayPixelsWide(display.displayID)
            config.height = CGDisplayPixelsHigh(display.displayID)
            config.showsCursor = false
            config.captureResolution = .best
            config.scalesToFit = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                   configuration: config)
            images[display.displayID] = image
        }

        // 吸附用的窗口几何。只留普通应用窗口（layer 0）：菜单栏、Dock、壁纸的
        // layer 都不是 0，正好一并滤掉。
        let frames = frontmostWindows()

        return CaptureResult(images: images, windows: frames)
    }

    /// 吸附候选窗口。用 CGWindowList 而不是 SCK 的 `content.windows`：前者的顺序
    /// **保证 front-to-back**，第一个命中鼠标的就是用户看到的最上层窗口；后者不保证顺序。
    /// 只要 geometry 和 owner，不涉及窗口标题，所以不需要额外权限。
    static func frontmostWindows() -> [WindowFrame] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let myPID = getpid()
        return list.compactMap { info in
            guard let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue, layer == 0,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let windowNumber = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.width >= 40, rect.height >= 40 else { return nil }
            // 自己的窗口默认不当吸附目标（菜单栏图标、覆盖层都在自己进程里），
            // 只有登记过的浏览器窗口例外
            if pid == myPID && !OwnedWindows.browser.contains(windowNumber) { return nil }
            return WindowFrame(rect: rect,
                               owner: (info[kCGWindowOwnerName as String] as? String) ?? "")
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

/// 一块屏一个覆盖窗。level 用 shielding（和系统截图/锁屏同层）才盖得住全屏 app 和 Dock；
/// collectionBehavior 让它跟着所有 Space 走。
final class SnapshotWindow: NSWindow {
    init(screen: NSScreen, image: CGImage, windowRects: [NSRect], controller: SnapshotController) {
        // 带 screen 的那个 init 是 convenience，子类里不能直接 super 调，只能指定初始化后改 frame
        super.init(contentRect: screen.frame,
                   styleMask: [.borderless],
                   backing: .buffered,
                   defer: false)
        setFrame(screen.frame, display: false)
        isOpaque = true
        backgroundColor = .black
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hasShadow = false
        isReleasedWhenClosed = false          // 窗口对象自己持有，不交给 AppKit 回收
        acceptsMouseMovedEvents = true        // 吸附要靠 mouseMoved

        let view = SnapshotView(cgImage: image,
                                frame: NSRect(origin: .zero, size: screen.frame.size),
                                windowRects: windowRects)
        view.controller = controller
        contentView = view
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// 覆盖层本体：画「变暗的全屏图 + 挖洞的亮选区」，负责框选交互与窗口吸附。
final class SnapshotView: NSView {

    private let cgImage: CGImage          // 原始像素，裁剪用
    private let screenImage: NSImage      // 屏幕上按点显示的那张
    private let windowRects: [NSRect]     // 吸附候选，front-to-back（第一个命中即最上层）
    private var selection: NSRect = .zero
    private var hoverRect: NSRect?        // 鼠标悬停到的窗口
    private var anchor: NSPoint?
    private var trackingArea: NSTrackingArea?
    weak var controller: SnapshotController?

    private let dimColor = NSColor.black.withAlphaComponent(0.45)

    init(cgImage: CGImage, frame: NSRect, windowRects: [NSRect] = []) {
        self.cgImage = cgImage
        self.screenImage = NSImage(cgImage: cgImage, size: frame.size)
        self.windowRects = windowRects
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        screenImage.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1,
                         respectFlipped: false, hints: nil)

        // 高亮谁：拖拽中看选区，没拖时看鼠标压在哪个窗口上
        let dragging = anchor != nil && selection.width > 0.5 && selection.height > 0.5
        let active = dragging ? selection : (hoverRect ?? .zero)
        let hovering = !dragging && hoverRect != nil
        let hasActive = active.width > 0.5 && active.height > 0.5

        // 遮罩：整块压暗，高亮区域用 even-odd 挖掉
        let mask = NSBezierPath(rect: bounds)
        if hasActive {
            mask.append(NSBezierPath(rect: active))
            mask.windingRule = .evenOdd
        }
        dimColor.setFill()
        mask.fill()

        guard hasActive else {
            drawHint()
            return
        }

        // 高亮区内按原亮度重画一遍
        screenImage.draw(in: active, from: active, operation: .sourceOver, fraction: 1,
                         respectFlipped: false, hints: nil)

        if hovering {
            // 窗口吸附：强调色单线，跟「手拖出来的选区」区分开
            let border = NSBezierPath(rect: active.insetBy(dx: 1, dy: 1))
            border.lineWidth = 2
            NSColor.controlAccentColor.setStroke()
            border.stroke()
            drawSizeLabel(for: active, prefix: "窗口 ", note: "　点击选中")
        } else {
            // 边框：内侧白线（2pt）+ 外侧半透明黑描边。
            // 1pt 细线在 4K 屏上会糊成一条灰边，加粗到 2pt 才有「框住」的感觉。
            let outer = NSBezierPath(rect: active.insetBy(dx: -2, dy: -2))
            outer.lineWidth = 2
            NSColor.black.withAlphaComponent(0.45).setStroke()
            outer.stroke()

            let border = NSBezierPath(rect: active.insetBy(dx: 1, dy: 1))
            border.lineWidth = 2
            NSColor.white.setStroke()
            border.stroke()

            drawSizeLabel(for: active, prefix: "", note: "")
        }
    }

    private func drawHint() {
        let text = "拖动选择截图区域　·　Esc 取消"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92)
        ]
        let size = text.size(withAttributes: attributes)
        let padding = NSSize(width: 14, height: 8)
        let rect = NSRect(x: bounds.midX - size.width / 2 - padding.width,
                          y: bounds.midY - size.height / 2 - padding.height,
                          width: size.width + padding.width * 2,
                          height: size.height + padding.height * 2)
        // 衬一层黑底：桌面上常常是白窗口，纯白字会糊掉
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        text.draw(at: NSPoint(x: rect.minX + padding.width, y: rect.minY + padding.height),
                  withAttributes: attributes)
    }

    private func drawSizeLabel(for rect: NSRect, prefix: String, note: String) {
        let text = "\(prefix)\(Int(rect.width.rounded())) × \(Int(rect.height.rounded()))\(note)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let textSize = text.size(withAttributes: attributes)
        let padding = NSSize(width: 8, height: 4)
        var origin = NSPoint(x: rect.minX,
                             y: rect.minY - textSize.height - padding.height * 2 - 6)
        if origin.y < bounds.minY + 4 {
            origin.y = rect.minY + 6      // 贴着屏幕底边就塞进选区里
        }
        let box = NSRect(x: origin.x, y: origin.y,
                         width: textSize.width + padding.width * 2,
                         height: textSize.height + padding.height * 2)
        let background = NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5)
        NSColor.black.withAlphaComponent(0.72).setFill()
        background.fill()
        text.draw(at: NSPoint(x: box.minX + padding.width, y: box.minY + padding.height),
                  withAttributes: attributes)
    }

    /// 调试用：把某一状态离屏渲染成 PNG —— 没有屏幕录制权限时靠它检查绘制。
    func renderPreview(to path: String, selection rect: NSRect, hover: NSRect? = nil) {
        selection = rect
        hoverRect = hover
        // draw() 里只有「正在拖」才认 selection（anchor != nil），预览没有鼠标事件，
        // 得手动给个 anchor，否则传进来的选区会被当成没选
        anchor = rect.width > 0.5 ? rect.origin : nil
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(bounds.width * scale),
                                         pixelsHigh: Int(bounds.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = bounds.size
        // 这里必须自己开一个绘图上下文直接 draw(bounds)：
        // 视图没有挂在窗口上，cacheDisplay 会复用上一次的 backing store，
        // 结果是第二次以后输出的 PNG 跟第一次一模一样（调试时差点被这个骗过去）。
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        draw(bounds)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
        print("→ \(path)  \(rep.pixelsWide)x\(rep.pixelsHigh)")
    }

    // MARK: 事件

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        let point = convert(event.locationInWindow, from: nil)
        anchor = point
        selection = NSRect(origin: point, size: .zero)
        hoverRect = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor else { return }
        let point = convert(event.locationInWindow, from: nil)
        selection = NSRect(x: min(anchor.x, point.x),
                           y: min(anchor.y, point.y),
                           width: abs(point.x - anchor.x),
                           height: abs(point.y - anchor.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = anchor else { return }
        anchor = nil
        let point = convert(event.locationInWindow, from: nil)
        let moved = hypot(point.x - start.x, point.y - start.y)

        // 拖了 → 自由框选
        if moved >= 3, selection.width >= 3, selection.height >= 3 {
            commit(selection)
            return
        }
        // 没拖、只是点了一下 → 落在哪个窗口上就选整个窗口
        if let windowRect = windowRects.first(where: { $0.contains(start) }) {
            commit(windowRect)
            return
        }
        selection = .zero
        hoverRect = windowRects.first { $0.contains(point) }
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        guard anchor == nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        let hit = windowRects.first { $0.contains(point) }
        guard hit != hoverRect else { return }     // 同一窗口内移动不重绘，省得每帧刷整屏
        hoverRect = hit
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.cancel()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:                    // Esc
            controller?.cancel()
        case 36, 76:                // Return / 小键盘 Enter
            if selection.width >= 3, selection.height >= 3 {
                commit(selection)
            } else if let hover = hoverRect {
                commit(hover)
            }
        default:
            super.keyDown(with: event)
        }
    }

    private func commit(_ rect: NSRect) {
        guard let cropped = croppedImage(for: rect) else {
            controller?.cancel()
            return
        }
        controller?.finish(image: cropped, pointSize: rect.size)
    }

    /// 视图坐标（原点左下、单位点）→ 截图像素坐标（原点左上、单位像素）
    private func croppedImage(for rect: NSRect) -> CGImage? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scaleX = CGFloat(cgImage.width) / bounds.width
        let scaleY = CGFloat(cgImage.height) / bounds.height
        let pixels = CGRect(x: (rect.minX * scaleX).rounded(.down),
                            y: ((bounds.height - rect.maxY) * scaleY).rounded(.down),
                            width: (rect.width * scaleX).rounded(),
                            height: (rect.height * scaleY).rounded())
        let limit = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        let clamped = pixels.intersection(limit).integral
        guard clamped.width >= 1, clamped.height >= 1 else { return nil }
        return cgImage.cropping(to: clamped)
    }
}

