//  Good-tools · AppDelegate：菜单栏常驻 + 各模块装配

import Cocoa
import Carbon.HIToolbox
import Darwin
import ServiceManagement
import UserNotifications

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var timer: Timer?
    private var snapshot: MemSnapshot?

    private let refreshInterval: TimeInterval = 5

    // ---- swap 读写速率（决定图标是否变红） ----------------------------------
    // 判定"频繁读写"用 vm_stat 的 Swapins/Swapouts 增量（累计值，取差），
    // 而不是 swap 用量 —— 用量涨上去会停住，但读写才是真正在磨盘的东西。
    private var lastSampleTime: Date?
    private var lastSwapIn: UInt64 = 0
    private var lastSwapOut: UInt64 = 0
    private var swapBytesPerSec: Double = 0
    private var swapOutBytesPerSec: Double = 0
    private var hotUntil: Date?          // 滞回：最后一次超阈值后再红 15 s

    private let hotThreshold: Double = 1_048_576      // 1 MB/s 起红
    private let coolThreshold: Double = 204_800       // 降到 0.2 MB/s 以下才算凉
    private let hotHoldSeconds: TimeInterval = 15

    // ---- 重负载弹窗 ---------------------------------------------------------
    // 触发条件刻意做得"钝"：swap 写入 ≥ 5 MB/s 且连续 3 拍（约 15 s）才提醒一次。
    // 然后 15 分钟冷却 + 每天最多 6 次 —— 宁可漏报，也不要在 swap 已经爆炸时
    // 再拿一堆 banner 动画去挤 WindowServer。
    private var overThresholdStreak = 0
    private var lastAlertAt: Date?
    private var alertsToday = 0
    private var alertDayKey = ""

    private let alertThreshold: Double = 5 * 1_048_576   // 只看写入侧（读不磨盘）
    private let alertSustainSamples = 3
    private let alertCooldown: TimeInterval = 15 * 60
    private let alertDailyCap = 6

    // ---- 移动硬盘温度 -------------------------------------------------------
    // 温度只在展开菜单里显示一行，菜单栏上不出现（菜单栏位置太贵）。
    // 过热同样让图标变红 + 弹窗，但冷却/每日上限与 swap 那套分开算，
    // 免得 swap 抖动把硬盘告警的名额吃光。
    private var driveTemps: [DriveTemp] = []
    private var driveHotDevices = Set<String>()     // 带滞回的"当前判热"集合
    private var lastDriveAlertAt: [String: Date] = [:]
    private var diskAlertsToday = 0

    private let diskAlertCooldown: TimeInterval = 30 * 60
    private let diskAlertDailyCap = 6
    private let diskCoolDrop = 3                    // 降回 阈值−3 才算凉

    private var diskThreshold: Int {
        if let d = debugThreshold { return d }        // 仅 --menu-dump 调试用
        let v = defaults.integer(forKey: "diskTempThreshold")
        return v > 0 ? v : 65
    }

    private let defaults = UserDefaults.standard
    private var notifStatusText = "未知"
    private var menuIsOpen = false
    /// 最近一次截图热键注册是否成功（设定页显示用）
    private(set) var snapshotHotKeyOK = true
    /// 仅调试入口（--menu-dump）用：临时覆盖过热阈值，不写进设置
    var debugThreshold: Int?

    /// 设定页（懒建：不点就不建窗口）
    private lazy var settings: SettingsWindowController = {
        let c = SettingsWindowController()
        c.app = self
        c.onNotifStatusChange = { [weak c] in c?.refreshNotifLabel() }
        return c
    }()

    /// 浏览器窗口（懒建：不点就不建 WebView，省内存）
    private lazy var browser = BrowserWindowController()

    // ---- 给设定页读的状态文案 ------------------------------------------------
    var notifStatus: String { notifStatusText }
    var swapAlertCount: Int { alertsToday }
    var swapAlertCap: Int { alertDailyCap }
    var diskAlertCount: Int { diskAlertsToday }
    var diskAlertCap: Int { diskAlertDailyCap }
    var swapAlertRule: String {
        "阈值 \(Int(alertThreshold / 1_048_576)) MB/s 持续 \(alertSustainSamples * 5)s · 冷却 \(Int(alertCooldown / 60)) 分钟"
    }
    var diskAlertRule: String {
        "采样 \(Int(DriveTempReader.shared.interval))s · 降回阈值−\(diskCoolDrop)℃ 转白 · 冷却 \(Int(diskAlertCooldown / 60)) 分钟"
    }

    func menuWillOpen(_ menu: NSMenu) { menuIsOpen = true }
    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        refreshNotifStatus()      // 关掉后补一次，下次打开就是新的
    }

    /// swap 侧的"红"：正在频繁换页，或内核判定内存压力为"紧急"
    private var swapHot: Bool {
        if let until = hotUntil, Date() < until { return true }
        return snapshot?.levelCode == 4
    }

    /// 移动硬盘侧的"红"：任意一块外置盘超过阈值
    private var diskHot: Bool { !driveHotDevices.isEmpty }

    /// 图标要不要变红
    private var isHot: Bool { swapHot || diskHot }

    // MARK: 单实例

    /// 菜单栏 app 被重复拉起会挂出好几个图标，所以第二个实例必须直接退出。
    /// 用 flock 而不是"按 bundle id 计数"：临时目录里编出来的副本 bundle id 也一样，
    /// 但算不同的 app，flock 能一并挡住。进程一死锁自动释放，不会留下僵尸锁。
    private var lockFD: Int32 = -1

    func acquireSingleInstanceLock() -> Bool {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("GoodTools", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("instance.lock").path

        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return true }        // 锁文件打不开就放行，别把自己锁死
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        lockFD = fd
        ftruncate(fd, 0)
        let text = "\(getpid())\n"
        _ = text.withCString { write(fd, $0, strlen($0)) }
        return true
    }

    /// 默认值只在这里注册一次（调试入口也要调，否则裸二进制读到的全是 0/false）
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: ["alertEnabled": true,
                                                  "alertSound": false,
                                                  "diskAlertEnabled": true,
                                                  "diskTempThreshold": 65,
                                                  "snapshotSound": true,
                                                  "snapshotHotKey": HotKeyCombo.snapshotDefault.rawValue])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // 不占 Dock

        Self.registerDefaults()
        Notifier.shared.setup()
        refreshNotifStatus()      // 启动就先探一次，别等打开菜单才显示"未知"

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "local.vincent.goodtools"
        if let button = statusItem.button {
            button.imagePosition = .imageLeft
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        }

        menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        // 菜单固定浅色外观：系统是深色模式时也保持白底黑字，比半透明灰底好读
        menu.appearance = NSAppearance(named: .aqua)
        statusItem.menu = menu

        // 截图热键从设定读（默认 ⌃⌘A），浏览器固定 ⌥⌘B。
        // 注册失败（被别的 app 占了）不致命，菜单里照样能点；设定页会标红提示。
        registerHotKeys()

        buildMainMenu()          // 浏览器窗口的 ⌘L / ⌘R / ⌘C 这些靠它

        refresh()

        let t = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func registerHotKeys() {
        applySnapshotHotKey()
        if !GlobalHotKey.shared.register(.browser,
                                         keyCode: kVK_ANSI_B,
                                         modifiers: cmdKey | optionKey,
                                         handler: { [weak self] in self?.openBrowser() }) {
            NSLog("Good-tools: 浏览器热键 ⌥⌘B 注册失败（可能被其他 app 占用）")
        }
    }

    /// 按当前设定注册/重注册截图热键。register 内部会先解绑同一个 action，
    /// 所以改键后直接再调一次即可，不用手动 UnregisterEventHotKey。
    @discardableResult
    func applySnapshotHotKey() -> Bool {
        let combo = HotKeyCombo.loadSnapshot()
        let ok = GlobalHotKey.shared.register(.snapshot,
                                              keyCode: combo.keyCode,
                                              modifiers: combo.modifiers) {
            SnapshotController.shared.trigger()
        }
        snapshotHotKeyOK = ok
        if !ok { NSLog("Good-tools: 截图热键 \(combo.displayText) 注册失败（可能被其他 app 占用）") }
        return ok
    }

    // MARK: 刷新

    @objc func refresh() {
        guard let snap = Sampler.sample() else {
            statusItem.button?.image = makeGaugeImage(fill: 0, color: .systemGray)
            statusItem.button?.attributedTitle = NSAttributedString(
                string: " —",
                attributes: [.font: NSFont.systemFont(ofSize: 11),
                             .foregroundColor: NSColor.secondaryLabelColor]
            )
            return
        }
        snapshot = snap

        updateSwapTraffic(snap)
        updateGauge(snap)
        refreshDriveTemps()      // 温度 30 s 一拍，内部自己判要不要真去采
    }

    /// 图标 + 菜单栏数字 + 悬浮提示。
    /// 硬盘温度是异步采回来的，到货后要再调一次这里刷新图标颜色与 tooltip。
    private func updateGauge(_ snap: MemSnapshot) {
        guard let button = statusItem?.button else { return }   // --menu-dump 之类没建状态栏时直接跳过
        // 图标 = 内存压力图样：白 = 正常，红 = swap 正在频繁读写 / 压力紧急 / 硬盘过热；
        // 亮起的格数 = swap 占用比。
        button.image = makeGaugeImage(fill: snap.swapRatio,
                                      color: isHot ? .systemRed : .labelColor)

        // 菜单栏文案：只有数字，39M/1G = 已用/分区容量（"swap" 字样只留在展开菜单里）
        button.attributedTitle = NSAttributedString(
            string: " " + swapNumbers(snap),
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                         .foregroundColor: NSColor.labelColor]
        )

        button.toolTip = toolTipText(snap)
    }

    private func toolTipText(_ snap: MemSnapshot) -> String {
        var lines = [
            "内存压力：\(snap.levelName)",
            "swap：已用 \(fmtBytes(snap.swapUsed)) / 分区 \(fmtBytes(snap.swapTotal))",
            "读写：\(trafficText())",
            "内存：已用 \(fmtBytes(snap.used)) / \(fmtBytes(snap.total)) · 余量 \(snap.availablePct)%"
        ]
        if driveTemps.isEmpty {
            lines.append("移动硬盘：未连接")
        } else {
            for d in driveTemps {
                let t = d.celsius.map { "\($0)°C" } ?? (d.missing ?? "温度不可读")
                lines.append("移动硬盘：\(d.displayName) \(t)")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: 移动硬盘温度

    private func refreshDriveTemps() {
        DriveTempReader.shared.refreshIfStale { [weak self] in
            guard let self else { return }
            self.applyDriveTemps(DriveTempReader.shared.drives)
        }
    }

    /// 收下新温度：维护"热/凉"滞回、按需弹窗，然后刷一次图标与提示（菜单开着就不重建）
    private func applyDriveTemps(_ drives: [DriveTemp]) {
        let th = diskThreshold
        let before = driveHotDevices
        var hot = Set<String>()
        for d in drives {
            guard let c = d.celsius else { continue }
            if c >= th {
                hot.insert(d.device)
            } else if c <= th - diskCoolDrop, before.contains(d.device) {
                hot.insert(d.device)          // 还没降到 阈值−3，继续算热（滞回）
            }
        }
        driveTemps = drives
        driveHotDevices = hot

        for d in drives where hot.contains(d.device) && !before.contains(d.device) {
            postDiskAlert(d)
        }

        if let snap = snapshot { updateGauge(snap) }
        if menuIsOpen { /* 菜单开着不重建，下次打开自然是最新的 */ }
    }

    private func postDiskAlert(_ d: DriveTemp) {
        guard defaults.bool(forKey: "diskAlertEnabled") else { return }
        let now = Date()
        rollDayIfNeeded(now)
        guard diskAlertsToday < diskAlertDailyCap else { return }
        if let last = lastDriveAlertAt[d.device], now.timeIntervalSince(last) < diskAlertCooldown {
            return
        }
        lastDriveAlertAt[d.device] = now
        diskAlertsToday += 1

        let limitNote = d.vendorLimit.map { "厂商临界温度 \($0)°C。" } ?? ""
        let body = """
        \(d.displayName)（\(d.device)）现在 \(d.celsius ?? 0)°C，已超过阈值 \(diskThreshold)°C。
        \(limitNote)建议暂停大文件读写，等温度回落。
        """
        Notifier.shared.post(title: "移动硬盘温度过高", body: body,
                             sound: defaults.bool(forKey: "alertSound"))
    }

    /// 每日计数按 yyyy-MM-dd 归零（swap / 硬盘两套计数一起滚）
    private func rollDayIfNeeded(_ now: Date) {
        let dayKey = Self.dayKeyFormatter.string(from: now)
        guard dayKey != alertDayKey else { return }
        alertDayKey = dayKey
        alertsToday = 0
        diskAlertsToday = 0
    }

    /// 用 Swapins/Swapouts 的增量算读写速率，并据此维护"红/白"状态（带滞回）
    private func updateSwapTraffic(_ snap: MemSnapshot) {
        let now = Date()
        defer {
            lastSampleTime = now
            lastSwapIn = snap.swapInPages
            lastSwapOut = snap.swapOutPages
        }
        guard let last = lastSampleTime else { return }   // 第一拍没有基准，跳过
        let dt = now.timeIntervalSince(last)
        guard dt > 0.5 else { return }

        let dIn = snap.swapInPages >= lastSwapIn ? snap.swapInPages - lastSwapIn : 0
        let dOut = snap.swapOutPages >= lastSwapOut ? snap.swapOutPages - lastSwapOut : 0
        let pageBytes = Double(Sampler.pageSize())
        swapBytesPerSec = Double(dIn + dOut) * pageBytes / dt
        swapOutBytesPerSec = Double(dOut) * pageBytes / dt

        if swapBytesPerSec >= hotThreshold {
            hotUntil = now.addingTimeInterval(hotHoldSeconds)
        } else if swapBytesPerSec < coolThreshold {
            // 已经凉下来：让滞回自然过期，不主动缩短
            if let until = hotUntil, now >= until { hotUntil = nil }
        }

        evaluateAlert(now: now)
    }

    /// 重负载弹窗：写入速率连续多拍超阈值才发，且受冷却与每日上限约束
    private func evaluateAlert(now: Date) {
        guard swapOutBytesPerSec >= alertThreshold else {
            overThresholdStreak = 0
            return
        }
        overThresholdStreak += 1
        guard overThresholdStreak >= alertSustainSamples else { return }
        guard defaults.bool(forKey: "alertEnabled") else { return }

        // 每日重置
        rollDayIfNeeded(now)
        guard alertsToday < alertDailyCap else { return }
        if let last = lastAlertAt, now.timeIntervalSince(last) < alertCooldown { return }

        lastAlertAt = now
        alertsToday += 1
        overThresholdStreak = 0     // 下一条提醒要重新攒够 3 拍

        let body = """
        swap 写入 \(fmtBytes(UInt64(swapOutBytesPerSec)))/s，已持续约 \(alertSustainSamples * 5) 秒
        已用 \(fmtBytes(snapshot?.swapUsed ?? 0)) / 分区 \(fmtBytes(snapshot?.swapTotal ?? 0)) · 内存压力 \(snapshot?.levelName ?? "?")
        """
        Notifier.shared.post(title: "swap 正在大量写入", body: body,
                             sound: defaults.bool(forKey: "alertSound"))
    }

    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func trafficText() -> String {
        if swapBytesPerSec < 1024 { return "空闲" }
        return fmtBytes(UInt64(swapBytesPerSec)) + "/s"
    }

    /// 菜单栏上的 39M/1G：左 = 已用，右 = 此刻分区容量
    private func swapNumbers(_ s: MemSnapshot) -> String {
        guard s.swapTotal > 0 else { return "0M" }
        return "\(fmtSwap(s.swapUsed))/\(fmtSwap(s.swapTotal))"
    }

    // MARK: 菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        // 打开菜单前重采一次，保证数字新鲜
        snapshot = Sampler.sample() ?? snapshot
        refreshNotifStatus()
        buildMenu()
    }

    /// 异步取系统通知权限，缓存成文案显示在菜单里（授权被拒时提醒是发不出来的）
    private func refreshNotifStatus(thenRebuild: Bool = false) {
        // 裸二进制（--dump/--settings-dump 之类，没有 .app 包）调 UNUserNotificationCenter 会直接
        // 抛 "bundleProxyForCurrentProcess is nil"，所以先确认自己在 bundle 里
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().getNotificationSettings { notifSettings in
            let names: [UNAuthorizationStatus: String] = [
                .notDetermined: "未询问", .denied: "被拒绝", .authorized: "已授权",
                .provisional: "临时授权"
            ]
            let text = names[notifSettings.authorizationStatus] ?? "未知"
            DispatchQueue.main.async {
                self.notifStatusText = text
                // 菜单正开着就别重建（会把列表抽掉），下次打开自然是最新的
                if thenRebuild && !self.menuIsOpen { self.buildMenu() }
                self.settings.onNotifStatusChange?()      // 设定页开着时让它自己更新那一行
            }
        }
    }

    /// 设定页里改了任何东西都走这里：重算冷热、刷图标、必要时重建菜单
    func settingsDidChange() {
        guard let snap = snapshot else { return }
        updateGauge(snap)
        if !menuIsOpen { buildMenu() }
    }

    /// 设定页改了快捷键：重注册 + 重建菜单文案（菜单开着就下次打开再更新）
    func snapshotHotKeyDidChange() {
        applySnapshotHotKey()
        if !menuIsOpen { buildMenu() }
    }

    /// 刚打开硬盘告警 / 改了开关：马上补采一次，别等 30 秒
    func forceDriveRefresh() {
        DriveTempReader.shared.refreshIfStale(force: true) { [weak self] in
            guard let self else { return }
            self.applyDriveTemps(DriveTempReader.shared.drives)
            if !self.menuIsOpen { self.buildMenu() }
        }
    }

    func refreshNotifStatusForSettings() {
        refreshNotifStatus(thenRebuild: false)
    }

    private func buildMenu() {
        menu.removeAllItems()
        guard let s = snapshot else {
            menu.addItem(infoItem("采样失败"))
            menu.addItem(.separator())
            menu.addItem(actionItem("退出", #selector(quit), key: "q"))
            return
        }

        // 第一行：压力等级
        menu.addItem(headerItem(s))

        // 第 2 行：swap（用户的主指标，放最前）
        menu.addItem(infoItem("swap　已用 \(fmtBytes(s.swapUsed)) / 分区 \(fmtBytes(s.swapTotal))　占用 \(Int((s.swapRatio * 100).rounded()))%"))
        menu.addItem(infoItem("swap 读写　\(trafficText())\(swapHot ? "（红：正在频繁换页）" : "")"))

        // 第 3 行：已用（Activity Monitor 口径：活跃 + 压缩 + Wired）
        // "余量" 就是 总量 − 已用，不是 memory_pressure 那个更宽的 free percentage
        menu.addItem(infoItem("已用 \(fmtBytes(s.used)) / \(fmtBytes(s.total))　余量 \(s.availablePct)%"))
        menu.addItem(infoItem("活跃 \(fmtBytes(s.appMemory))　压缩 \(fmtBytes(s.compressed))　Wired \(fmtBytes(s.wired))"))

        // 移动硬盘温度：只在这里出现，菜单栏上不显示
        if driveTemps.isEmpty {
            menu.addItem(infoItem("移动硬盘　未连接"))
        } else {
            for d in driveTemps {
                menu.addItem(driveTempItem(d, hot: driveHotDevices.contains(d.device)))
            }
        }

        menu.addItem(.separator())
        menu.addItem(actionItem("浏览器　⌥⌘B", #selector(openBrowser), key: ""))
        menu.addItem(actionItem("截图　\(HotKeyCombo.loadSnapshot().displayText)", #selector(takeScreenshot), key: ""))
        if !SnapshotController.hasPermission {
            menu.addItem(screenPermissionItem())
        }
        menu.addItem(actionItem("刷新", #selector(refresh), key: "r"))
        menu.addItem(actionItem("打开活动监视器", #selector(openActivityMonitor), key: ""))

        menu.addItem(.separator())
        menu.addItem(actionItem("设定…", #selector(openSettings), key: ","))
        menu.addItem(actionItem("退出 Good-tools", #selector(quit), key: "q"))
    }

    /// 信息行一律用自定义 view，不用普通的禁用菜单项。
    /// 原因（踩过）：普通菜单项一旦 isEnabled = false，AppKit 会把它当"不可用"来画 ——
    /// 灰色是**系统画的**，attributedTitle 里写纯黑也会被压暗。自定义 view 不受这个规则影响。
    private func infoItem(_ text: String, size: CGFloat = 12, bold: Bool = false) -> NSMenuItem {
        let label = NSTextField(labelWithAttributedString: NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: size,
                                                        weight: bold ? .semibold : .regular),
                .foregroundColor: NSColor.black
            ]
        ))
        return viewItem(label)
    }

    /// 把一行（可能是带颜色的富文本）包成不可选中的菜单行
    private func viewItem(_ label: NSTextField) -> NSMenuItem {
        label.sizeToFit()
        let height = max(20, label.frame.height + 7)
        let container = NSView(frame: NSRect(x: 0, y: 0,
                                             width: label.frame.width + 32,
                                             height: height))
        // 左缩进 14pt 与普通菜单项的文字起点对齐
        label.setFrameOrigin(NSPoint(x: 14, y: (height - label.frame.height) / 2))
        container.addSubview(label)

        let item = NSMenuItem()
        item.view = container
        item.isEnabled = false          // 不可选：没有 hover 高亮
        return item
    }

    /// 第一行：压力等级（红只看 swap 侧 —— 内存正常却被硬盘连坐标红会看不懂；
    /// 硬盘过热由它自己那一行标红，图标同样是红的）
    private func headerItem(_ s: MemSnapshot) -> NSMenuItem {
        let color: NSColor = swapHot ? .systemRed : .black
        let text = NSMutableAttributedString()
        text.append(NSAttributedString(string: "● ", attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: color
        ]))
        text.append(NSAttributedString(string: "内存压力：\(s.levelName)", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: color
        ]))
        return viewItem(NSTextField(labelWithAttributedString: text))
    }

    /// 移动硬盘温度那一行；过热时整行红，读不到就写原因
    private func driveTempItem(_ d: DriveTemp, hot: Bool) -> NSMenuItem {
        let tempText = d.celsius.map { "\($0)°C" } ?? "—"
        var text = "移动硬盘　\(d.displayName)　\(tempText)"
        if d.celsius == nil { text += "　\(d.missing ?? "温度不可读")" }
        if hot { text += "　（过热 >\(diskThreshold)°C）" }

        let label = NSTextField(labelWithAttributedString: NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12,
                                                        weight: hot ? .semibold : .regular),
                .foregroundColor: hot ? NSColor.systemRed : NSColor.black
            ]
        ))
        return viewItem(label)
    }

    private func actionItem(_ text: String, _ sel: Selector, key: String) -> NSMenuItem {

        let item = NSMenuItem(title: text, action: sel, keyEquivalent: key)
        item.target = self
        item.isEnabled = true
        return item
    }

    /// 「没屏幕录制权限」那一行：红字，点一下同时发起申请 + 跳系统设置
    private func screenPermissionItem() -> NSMenuItem {
        let item = NSMenuItem(title: "需要「屏幕录制」权限（点此授权）",
                              action: #selector(requestScreenPermission),
                              keyEquivalent: "")
        item.target = self
        item.attributedTitle = NSAttributedString(
            string: "⚠︎ 需要「屏幕录制」权限（点此授权）",
            attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                         .foregroundColor: NSColor.systemRed]
        )
        return item
    }

    // MARK: 动作

    @objc func takeScreenshot() {
        SnapshotController.shared.trigger()
    }

    @objc func openBrowser() {
        browser.toggle()
    }

    @objc func requestScreenPermission() {
        _ = SnapshotController.requestPermission()
        SnapshotController.openScreenRecordingSettings()
    }

    @objc func openActivityMonitor() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    @objc func openSettings() {
        settings.show()
    }

    @objc func testNotification() {
        Notifier.shared.printStatus(label: "测试")
        Notifier.shared.post(title: "Good-tools 测试提醒",
                             body: "看到这条就说明弹窗通路是通的。",
                             sound: defaults.bool(forKey: "alertSound"))
    }

    @objc func openNotificationSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
            ?? URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!
        NSWorkspace.shared.open(url)
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }

    /// 关浏览器窗口 ≠ 退出 app：菜单栏还得留着
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: 浏览器用的主菜单
    //
    // 菜单栏 app 平时没有菜单，但浏览器窗口切到 .regular 后要能按 ⌘L / ⌘R / ⌘C 这些。
    // 动作全部走 nil target，沿响应链找到 BrowserViewController。
    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "关于 Good-tools",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "设定…", action: #selector(openSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 Good-tools", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "隐藏其他",
                                         action: #selector(NSApplication.hideOtherApplications(_:)),
                                         keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "显示全部",
                        action: #selector(NSApplication.unhideAllApplications(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 Good-tools", action: #selector(quit), keyEquivalent: "q")

        // 编辑：剪贴板快捷键依赖菜单存在
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "撤销", action: #selector(UndoManager.undo), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "重做", action: #selector(UndoManager.redo), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // 浏览
        let navItem = NSMenuItem()
        main.addItem(navItem)
        let navMenu = NSMenu(title: "浏览")
        navItem.submenu = navMenu
        navMenu.addItem(withTitle: "后退", action: #selector(BrowserViewController.goBackAction), keyEquivalent: "[")
        navMenu.addItem(withTitle: "前进", action: #selector(BrowserViewController.goForwardAction), keyEquivalent: "]")
        navMenu.addItem(withTitle: "刷新", action: #selector(BrowserViewController.reloadAction), keyEquivalent: "r")
        navMenu.addItem(withTitle: "聚焦地址栏", action: #selector(BrowserViewController.focusAddressBar), keyEquivalent: "l")
        navMenu.addItem(withTitle: "收藏当前页", action: #selector(BrowserViewController.toggleBookmarkAction), keyEquivalent: "d")
        navMenu.addItem(.separator())
        navMenu.addItem(withTitle: "放大", action: #selector(BrowserViewController.zoomIn), keyEquivalent: "+")
        navMenu.addItem(withTitle: "缩小", action: #selector(BrowserViewController.zoomOut), keyEquivalent: "-")
        navMenu.addItem(withTitle: "实际大小", action: #selector(BrowserViewController.zoomReset), keyEquivalent: "0")
        navMenu.addItem(.separator())
        navMenu.addItem(withTitle: "查看当前 UA…", action: #selector(BrowserViewController.showCurrentUA), keyEquivalent: "u")
        navMenu.addItem(.separator())
        navMenu.addItem(withTitle: "截图", action: #selector(takeScreenshot), keyEquivalent: "")

        // 窗口
        let winItem = NSMenuItem()
        main.addItem(winItem)
        let winMenu = NSMenu(title: "窗口")
        winItem.submenu = winMenu
        winMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")

        NSApp.mainMenu = main
    }

    /// 调试用：按当前设定注册热键并把结果打出来（不建菜单栏、不跑主循环）
    func debugRegisterHotKeys() {
        let snap = HotKeyCombo.loadSnapshot()
        let a = GlobalHotKey.shared.register(.snapshot, keyCode: snap.keyCode,
                                             modifiers: snap.modifiers) {}
        let b = GlobalHotKey.shared.register(.browser, keyCode: kVK_ANSI_B,
                                             modifiers: cmdKey | optionKey) {}
        print("截图 \(snap.displayText)=\(a ? "ok" : "fail")  ⌥⌘B=\(b ? "ok" : "fail")")
    }

    /// 调试用：只把设定页构建出来，打印控件状态，不显示窗口
    func debugSettingsSummary() {
        settings.app = self
        print(settings.debugSummary())
    }

    /// 调试用：把设定页渲染成 PNG，检查排版有没有挤在一起
    func debugSettingsPreview(to path: String, appearanceName: NSAppearance.Name? = nil) {
        settings.app = self
        settings.writePreviewPNG(to: path, appearanceName: appearanceName)
    }

    /// 调试用：不建状态栏图标、不弹窗，只把菜单构建一遍并把每行文字（含红色标记）打出来。
    /// 改菜单排版 / 新加指标后用它做回归，省得靠肉眼看菜单。
    func dumpMenuForDebug() {
        menu = NSMenu()
        menu.autoenablesItems = false
        snapshot = Sampler.sample()
        applyDriveTemps(DriveTempReader.probe().drives)   // 同步采一次盘温
        buildMenu()

        for item in menu.items {
            if item.isSeparatorItem { print("──"); continue }
            if let label = item.view?.subviews.first as? NSTextField {
                let attr = label.attributedStringValue
                let color = attr.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
                print((color == .systemRed ? "[RED] " : "      ") + attr.string)
            } else {
                print((item.state == .on ? "[x]   " : "[ ]   ") + item.title)
            }
        }
    }
}
