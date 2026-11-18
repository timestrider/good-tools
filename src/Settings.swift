//  Good-tools · 设定窗口

import Cocoa
import ServiceManagement
import UserNotifications

// MARK: - 设定窗口

/// 设定页：所有开关与阈值都收在这里，菜单只留状态行和几个动作。
/// 纯 AppKit 手写布局（不用 xib / SwiftUI）—— 这 app 只有一个文件，多引一层反而更脆。
final class SettingsWindowController: NSObject, NSWindowDelegate {

    weak var app: AppDelegate?
    /// 通知权限是异步查的，查回来让窗口自己更新那一行
    var onNotifStatusChange: (() -> Void)?

    private var window: NSWindow?
    private let defaults = UserDefaults.standard
    private let thresholdOptions = [60, 65, 70, 75, 80]

    private let loginCheck = NSButton(checkboxWithTitle: "开机自启（登录时启动）",
                                      target: nil, action: nil)
    private let swapAlertCheck = NSButton(checkboxWithTitle: "swap 大量写入时提醒",
                                          target: nil, action: nil)
    private let soundCheck = NSButton(checkboxWithTitle: "提醒时带声音",
                                      target: nil, action: nil)
    private let diskAlertCheck = NSButton(checkboxWithTitle: "移动硬盘过热时提醒",
                                          target: nil, action: nil)
    private let thresholdPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let swapStat = NSTextField(labelWithString: "")
    private let diskStat = NSTextField(labelWithString: "")
    private let notifLabel = NSTextField(labelWithString: "")
    private let snapshotSoundCheck = NSButton(checkboxWithTitle: "截图后播放提示音",
                                              target: nil, action: nil)
    /// 截图呼出键：点一下进入录制，按键即改。懒建，保证读到已注册的 UserDefaults 默认值。
    private lazy var snapshotKeyRecorder = HotKeyRecorder(combo: HotKeyCombo.loadSnapshot())
    private let snapshotKeyStat = NSTextField(labelWithString: "")
    private let screenPermissionLabel = NSTextField(labelWithString: "")

    // MARK: 显示

    func show() {
        if window == nil { window = buildWindow() }
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// 调试入口用：建好窗口但不显示，返回各控件状态
    func debugSummary() -> String {
        if window == nil { window = buildWindow() }
        refresh()
        let size = window?.frame.size ?? .zero
        return """
        window=\(Int(size.width))x\(Int(size.height))
        login=\(loginCheck.state == .on ? "on" : "off")
        swapAlert=\(swapAlertCheck.state == .on ? "on" : "off")  sound=\(soundCheck.state == .on ? "on" : "off")  soundEnabled=\(soundCheck.isEnabled)
        diskAlert=\(diskAlertCheck.state == .on ? "on" : "off")  threshold=\(thresholdPopup.titleOfSelectedItem ?? "?")℃
        snapshotHotKey=\(snapshotKeyRecorder.combo.displayText)  registered=\(app?.snapshotHotKeyOK ?? false)
        \(swapStat.stringValue)
        \(diskStat.stringValue)
        \(notifLabel.stringValue)
        """
    }

    func windowWillClose(_ notification: Notification) {
        // 关掉只是隐藏（isReleasedWhenClosed = false），下次直接复用
    }

    func refreshNotifLabel() {
        guard let app else { return }
        notifLabel.stringValue = "系统通知权限：\(app.notifStatus)"
    }

    /// 调试用：把窗口内容渲染成 PNG（不需要屏幕录制权限，纯离屏绘制）
    /// 写法照抄 renderIconPreview：先手动建 bitmap context，再套一层浅色外观 ——
    /// 直接 cacheDisplay 会沿用进程当前外观（深色），出来是白字白底。
    func writePreviewPNG(to path: String, appearanceName: NSAppearance.Name? = nil) {
        if window == nil { window = buildWindow() }
        if let name = appearanceName { window?.appearance = NSAppearance(named: name) }
        refresh()
        guard let view = window?.contentView else { return }
        view.layoutSubtreeIfNeeded()

        let scale: CGFloat = 2
        let size = view.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(size.width * scale),
                                         pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size

        let appearance = window?.appearance ?? NSApp.effectiveAppearance
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        appearance.performAsCurrentDrawingAppearance {
            // 用窗口自己的背景色（动态色，跟着外观走），别写死白色
            (window?.backgroundColor ?? NSColor.windowBackgroundColor).setFill()
            NSRect(origin: .zero, size: size).fill()
            view.cacheDisplay(in: view.bounds, to: rep)
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
        print("→ \(path)  \(rep.pixelsWide)x\(rep.pixelsHigh)")
    }

    // MARK: 布局

    private func buildWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "Good-tools 设定"
        w.isReleasedWhenClosed = false          // 关掉只隐藏，别每次重建
        // 窗口不强制浅色：交给系统外观，文字用动态色（.labelColor）自动反色；
        // 只有菜单那边是固定浅色的（菜单半透明灰底配深色字不好读）
        w.delegate = self
        w.setFrameAutosaveName("local.vincent.goodtools.settings")

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill              // 别让多余高度被分摊成间距
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false

        // ---- 通用
        stack.addArrangedSubview(sectionTitle("通用"))
        loginCheck.target = self
        loginCheck.action = #selector(toggleLogin)
        stack.addArrangedSubview(loginCheck)
        stack.addArrangedSubview(hint("注册到「系统设置 → 通用 → 登录项与扩展」。若那里显示「需要批准」，去点一下允许。"))

        stack.addArrangedSubview(separator())

        // ---- swap 告警
        stack.addArrangedSubview(sectionTitle("swap 告警"))
        swapAlertCheck.target = self
        swapAlertCheck.action = #selector(toggleSwapAlert)
        stack.addArrangedSubview(swapAlertCheck)
        soundCheck.target = self
        soundCheck.action = #selector(toggleSound)
        stack.addArrangedSubview(indented(soundCheck))
        styleStat(swapStat)
        stack.addArrangedSubview(indented(swapStat))
        stack.addArrangedSubview(hint("只看写入侧：≥ 5 MB/s 且连续 15 秒才提醒（读不磨盘）。宁可漏报，也不在 swap 已经爆炸时再拿一堆 banner 动画去挤 WindowServer。"))

        stack.addArrangedSubview(separator())

        // ---- 移动硬盘
        stack.addArrangedSubview(sectionTitle("移动硬盘温度"))
        diskAlertCheck.target = self
        diskAlertCheck.action = #selector(toggleDiskAlert)
        stack.addArrangedSubview(diskAlertCheck)

        thresholdPopup.addItems(withTitles: thresholdOptions.map { "\($0)" })
        thresholdPopup.target = self
        thresholdPopup.action = #selector(changeThreshold)
        let thRow = NSStackView(views: [
            NSTextField(labelWithString: "过热阈值"),
            thresholdPopup,
            NSTextField(labelWithString: "℃")
        ])
        thRow.orientation = .horizontal
        thRow.spacing = 8
        thRow.alignment = .firstBaseline
        stack.addArrangedSubview(indented(thRow))

        styleStat(diskStat)
        stack.addArrangedSubview(indented(diskStat))
        stack.addArrangedSubview(hint("每 30 秒采一次：diskutil 读 SMART 里的温度（纯读命令，不计写入寿命，不动 NAND）。升到阈值即红，降回阈值−3 ℃ 才转白；休眠中的盘用 -n standby 放过，不会去叫醒它。"))

        stack.addArrangedSubview(separator())

        // ---- 截图
        stack.addArrangedSubview(sectionTitle("截图"))

        let keyRow = NSStackView(views: [
            NSTextField(labelWithString: "呼出快捷键"),
            snapshotKeyRecorder
        ])
        keyRow.orientation = .horizontal
        keyRow.spacing = 10
        keyRow.alignment = .firstBaseline
        stack.addArrangedSubview(indented(keyRow))
        snapshotKeyRecorder.onCommit = { [weak self] combo in
            self?.commitHotKey(combo)
        }
        snapshotKeyRecorder.onCancel = { [weak self] in
            self?.refreshSnapshotKeyStat()
        }
        styleStat(snapshotKeyStat)
        stack.addArrangedSubview(indented(snapshotKeyStat))

        snapshotSoundCheck.target = self
        snapshotSoundCheck.action = #selector(toggleSnapshotSound)
        stack.addArrangedSubview(snapshotSoundCheck)
        styleStat(screenPermissionLabel)
        stack.addArrangedSubview(screenPermissionLabel)
        let permBtn = NSButton(title: "打开屏幕录制设置…", target: self,
                               action: #selector(openScreenRecordingSettings))
        stack.addArrangedSubview(permBtn)
        stack.addArrangedSubview(hint("点快捷键按钮后按下新组合键（至少带一个 ⌘ / ⌃ / ⌥ / ⇧），Esc 取消。截图时拖动自由框选，或鼠标悬停到窗口上单击整块；松开即复制到剪贴板，Enter 复制当前选区。"))

        stack.addArrangedSubview(separator())

        // ---- 通知
        stack.addArrangedSubview(sectionTitle("通知"))
        notifLabel.font = .systemFont(ofSize: 12)
        stack.addArrangedSubview(notifLabel)
        let testBtn = NSButton(title: "发送一条测试提醒", target: self, action: #selector(sendTest))
        let openBtn = NSButton(title: "打开通知设置…", target: self, action: #selector(openNotifSettings))
        let btnRow = NSStackView(views: [testBtn, openBtn])
        btnRow.orientation = .horizontal
        btnRow.spacing = 8
        stack.addArrangedSubview(btnRow)

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 18)
        ])
        w.contentView = container
        container.layoutSubtreeIfNeeded()
        let height = stack.fittingSize.height + 36
        w.setContentSize(NSSize(width: 460, height: height))
        container.layoutSubtreeIfNeeded()      // 尺寸定下来再排一次，fittingSize 才准
        w.center()
        return w
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .labelColor
        return label
    }

    private func hint(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 420
        label.widthAnchor.constraint(equalToConstant: 420).isActive = true
        return label
    }

    private func styleStat(_ label: NSTextField) {
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
    }

    /// 左边留 18pt，跟分组里的控件对齐
    private func indented(_ view: NSView) -> NSStackView {
        let spacer = NSView()
        spacer.widthAnchor.constraint(equalToConstant: 18).isActive = true
        let row = NSStackView(views: [spacer, view])
        row.orientation = .horizontal
        row.spacing = 0
        return row
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 420).isActive = true
        return box
    }

    // MARK: 刷新控件状态

    private func refresh() {
        guard let app else { return }
        loginCheck.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        swapAlertCheck.state = defaults.bool(forKey: "alertEnabled") ? .on : .off
        soundCheck.state = defaults.bool(forKey: "alertSound") ? .on : .off
        soundCheck.isEnabled = swapAlertCheck.state == .on
        diskAlertCheck.state = defaults.bool(forKey: "diskAlertEnabled") ? .on : .off
        thresholdPopup.isEnabled = diskAlertCheck.state == .on
        let rawTh = defaults.integer(forKey: "diskTempThreshold")
        let th = rawTh > 0 ? rawTh : 65
        thresholdPopup.selectItem(withTitle: "\(th)")
        swapStat.stringValue = "今日 \(app.swapAlertCount)/\(app.swapAlertCap) · \(app.swapAlertRule)"
        diskStat.stringValue = "今日 \(app.diskAlertCount)/\(app.diskAlertCap) · \(app.diskAlertRule)"
        snapshotSoundCheck.state = defaults.bool(forKey: "snapshotSound") ? .on : .off
        refreshSnapshotKeyStat()
        screenPermissionLabel.stringValue = SnapshotController.hasPermission
            ? "屏幕录制权限：已授权"
            : "屏幕录制权限：未授权（截图会走不通，点下面按钮去开）"
        refreshNotifLabel()
        app.refreshNotifStatusForSettings()
    }

    // MARK: 动作

    /// 录到新组合：先挡掉和浏览器热键撞车的，再落盘 + 即时重注册
    private func commitHotKey(_ combo: HotKeyCombo) {
        if combo == .browserDefault {
            NSSound.beep()
            snapshotKeyStat.stringValue = "⚠ 与浏览器快捷键 ⌥⌘B 冲突，换一个"
            snapshotKeyStat.textColor = .systemRed
            return
        }
        combo.saveSnapshot()
        app?.snapshotHotKeyDidChange()
        refreshSnapshotKeyStat()
    }

    private func refreshSnapshotKeyStat() {
        let combo = HotKeyCombo.loadSnapshot()
        snapshotKeyRecorder.combo = combo
        if let ok = app?.snapshotHotKeyOK, !ok {
            snapshotKeyStat.stringValue = "⚠ \(combo.displayText) 注册失败，可能被其他 app 占用"
            snapshotKeyStat.textColor = .systemRed
        } else {
            snapshotKeyStat.stringValue = "当前：\(combo.displayText) · 点击按钮可改"
            snapshotKeyStat.textColor = .secondaryLabelColor
        }
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "无法修改开机自启"
            alert.informativeText = """
            操作失败：\(error.localizedDescription)

            可以手动添加：系统设置 → 通用 → 登录项与扩展 → 加号 → 选择
            \(Bundle.main.bundlePath)
            """
            alert.alertStyle = .warning
            if let w = window {
                alert.beginSheetModal(for: w, completionHandler: nil)
            } else {
                alert.runModal()
            }
        }
        refresh()
        app?.settingsDidChange()
    }

    @objc private func toggleSwapAlert() {
        let on = swapAlertCheck.state == .on
        defaults.set(on, forKey: "alertEnabled")
        if on { Notifier.shared.setup() }      // 已拒绝过就不会再弹系统授权框
        refresh()
        app?.settingsDidChange()
    }

    @objc private func toggleSound() {
        defaults.set(soundCheck.state == .on, forKey: "alertSound")
        app?.settingsDidChange()
    }

    @objc private func toggleDiskAlert() {
        let on = diskAlertCheck.state == .on
        defaults.set(on, forKey: "diskAlertEnabled")
        if on {
            Notifier.shared.setup()
            app?.forceDriveRefresh()
        }
        refresh()
        app?.settingsDidChange()
    }

    @objc private func changeThreshold() {
        guard let title = thresholdPopup.titleOfSelectedItem, let value = Int(title) else { return }
        defaults.set(value, forKey: "diskTempThreshold")
        refresh()
        app?.settingsDidChange()      // 阈值变了要立刻重判冷热（图标颜色跟着变）
    }

    @objc private func toggleSnapshotSound() {
        defaults.set(snapshotSoundCheck.state == .on, forKey: "snapshotSound")
    }

    @objc private func openScreenRecordingSettings() {
        SnapshotController.openScreenRecordingSettings()
    }

    @objc private func sendTest() { app?.testNotification() }
    @objc private func openNotifSettings() { app?.openNotificationSettings() }
}

