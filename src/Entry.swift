//  Good-tools · 入口与调试开关

import Cocoa

@main
struct GoodToolsApp {

    /// NSApplication.delegate 是 weak，必须在这里强引用住
    static let delegate = AppDelegate()

    static func main() {
        AppDelegate.registerDefaults()

        // 调试：打印一行快照后退出（不算 bug，留给排查用）
        if CommandLine.arguments.contains("--dump") {
            guard let s = Sampler.sample() else {
                print("sample failed")
                exit(1)
            }
            print("level=\(s.levelCode) (\(s.levelName))  used=\(fmtBytes(s.used))  "
                  + "total=\(fmtBytes(s.total))  available=\(s.availablePct)%  "
                  + "swap=\(fmtBytes(s.swapUsed))/\(fmtBytes(s.swapTotal))  "
                  + "swapIn=\(s.swapInPages)  swapOut=\(s.swapOutPages)  "
                  + "app=\(fmtBytes(s.appMemory))  compressed=\(fmtBytes(s.compressed))  "
                  + "wired=\(fmtBytes(s.wired))")
            // 外置盘温度也打一份，方便排查"菜单里为什么没这一行"
            let probe = DriveTempReader.probe()
            if probe.drives.isEmpty {
                print("disk: (无外置物理盘)\(probe.error.map { "  error=\($0)" } ?? "")")
            }
            for d in probe.drives {
                let t = d.celsius.map { "\($0)C" } ?? "n/a"
                let limit = d.vendorLimit.map { "\($0)C" } ?? "-"
                print("disk=\(d.device)  model=\(d.displayName)  temp=\(t)  "
                      + "vendorLimit=\(limit)  note=\(d.missing ?? "-")")
            }
            exit(0)
        }

        // 调试：只采外置盘温度，不碰内存、不起 UI
        //   --disk-dump [阈值]  给个数字就按这个阈值判"过热"，不给就用设置里的
        if CommandLine.arguments.contains("--disk-dump") {
            var th = UserDefaults.standard.integer(forKey: "diskTempThreshold")
            if th <= 0 { th = 65 }
            if let override = CommandLine.arguments.compactMap({ Int($0) }).first { th = override }
            let probe = DriveTempReader.probe()
            if let error = probe.error { print("error=\(error)") }
            if probe.drives.isEmpty { print("(无外置物理盘)") }
            for d in probe.drives {
                let t = d.celsius.map { "\($0)C" } ?? "n/a"
                let hot = d.celsius.map { $0 >= th } ?? false
                print("disk=\(d.device)  model=\(d.displayName)  size=\(fmtBytes(d.sizeBytes))  "
                      + "temp=\(t)  threshold=\(th)C  hot=\(hot)  note=\(d.missing ?? "-")")
            }
            exit(0)
        }

        // 调试：把设定页建出来但不显示，只打印控件状态（回归用）
        if CommandLine.arguments.contains("--settings-dump") {
            NSApplication.shared.setActivationPolicy(.prohibited)
            let debugDelegate = AppDelegate()
            debugDelegate.debugSettingsSummary()
            exit(0)
        }

        // 调试：把设定页渲染成 PNG（离屏绘制，不需要屏幕录制权限）
        //   --settings-preview <path> [light|dark]  可选指定外观，验证深浅两种下的可读性
        if let idx = CommandLine.arguments.firstIndex(of: "--settings-preview"),
           idx + 1 < CommandLine.arguments.count {
            NSApplication.shared.setActivationPolicy(.prohibited)
            let debugDelegate = AppDelegate()
            let extra = idx + 2 < CommandLine.arguments.count ? CommandLine.arguments[idx + 2] : ""
            let appearanceName: NSAppearance.Name? = extra == "light" ? .aqua
                : (extra == "dark" ? .darkAqua : nil)
            debugDelegate.debugSettingsPreview(to: CommandLine.arguments[idx + 1],
                                               appearanceName: appearanceName)
            exit(0)
        }

        // 调试：把菜单构建一遍并打印每行文字（不挂状态栏、不发通知）
        //   --menu-dump [阈值] 给个数字就临时按这个阈值判过热（不写进设置）
        if CommandLine.arguments.contains("--menu-dump") {
            NSApplication.shared.setActivationPolicy(.prohibited)
            let debugDelegate = AppDelegate()
            debugDelegate.debugThreshold = CommandLine.arguments.compactMap { Int($0) }.first
            debugDelegate.dumpMenuForDebug()
            exit(0)
        }

        // 调试：把图标在不同 swap 占比 / 三种压力色下的样子渲染成 PNG（8 倍放大），
        // 深浅两种外观各一张。没有屏幕录制权限时靠它做视觉自检。
        if let idx = CommandLine.arguments.firstIndex(of: "--icon-preview"),
           idx + 1 < CommandLine.arguments.count {
            let base = CommandLine.arguments[idx + 1]
            renderIconPreview(to: base)
            exit(0)
        }

        // 调试：用合成桌面图把覆盖层渲染成 PNG（不需要屏幕录制权限）
        //   --snapshot-preview <base>   产出 <base>-hint.png / <base>-sel.png
        if let idx = CommandLine.arguments.firstIndex(of: "--snapshot-preview"),
           idx + 1 < CommandLine.arguments.count {
            NSApplication.shared.setActivationPolicy(.prohibited)
            let path = CommandLine.arguments[idx + 1]
            let base = path.hasSuffix(".png") ? String(path.dropLast(4)) : path
            let size = NSSize(width: 960, height: 600)
            guard let cg = makeDummyScreenshot(size: size) else { exit(1) }
            let view = SnapshotView(cgImage: cg, frame: NSRect(origin: .zero, size: size))
            view.renderPreview(to: "\(base)-hint.png", selection: .zero)
            view.renderPreview(to: "\(base)-sel.png",
                               selection: NSRect(x: 220, y: 150, width: 460, height: 280))
            view.renderPreview(to: "\(base)-window.png",
                               selection: .zero,
                               hover: NSRect(x: 120, y: 80, width: 720, height: 440))
            exit(0)
        }

        // 调试：抓一次全屏存 PNG（验证 ScreenCaptureKit 通路 + 屏幕录制权限）
        //   --snapshot-capture [out.png]   不传路径就写 /tmp/snapshot.png
        if let idx = CommandLine.arguments.firstIndex(of: "--snapshot-capture") {
            let out = idx + 1 < CommandLine.arguments.count && !CommandLine.arguments[idx + 1].hasPrefix("-")
                ? CommandLine.arguments[idx + 1] : "/tmp/snapshot.png"
            NSApplication.shared.setActivationPolicy(.prohibited)

            var captured: CGImage?
            var windowCount = 0
            var failure: String?
            var finished = false
            Task {
                do {
                    let result = try await SnapshotController.captureAllDisplays()
                    captured = result.images.values.first
                    windowCount = result.windows.count
                } catch { failure = "\(error)" }
                finished = true
            }
            // 用 runloop 等而不是信号量：阻塞主线程会把 async 回调饿死
            let deadline = Date().addingTimeInterval(20)
            while !finished, Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }

            if let image = captured,
               let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: out))
                print("→ \(out)  \(image.width)x\(image.height)  吸附候选窗口 \(windowCount) 个")
                exit(0)
            }
            print("capture failed: \(failure ?? "timeout")")
            exit(1)
        }

        // 调试：发一条测试通知（会先请求权限），用来验证弹窗通路
        if CommandLine.arguments.contains("--test-notify") {
            NSApplication.shared.setActivationPolicy(.accessory)
            Notifier.shared.setup()
            // 经 launchd 启动时 stdout 没有终端，所以同时写一份到 /tmp
            Notifier.shared.printStatus(label: "启动", alsoToFile: "/tmp/mempressure-notify.log")
            RunLoop.current.run(until: Date().addingTimeInterval(6))
            Notifier.shared.post(title: "Good-tools 测试提醒",
                                 body: "如果看到这条，说明弹窗通路可用。",
                                 sound: false)
            Notifier.shared.printStatus(label: "发送后", alsoToFile: "/tmp/mempressure-notify.log")
            RunLoop.current.run(until: Date().addingTimeInterval(3))
            exit(0)
        }

        // 调试：试注册两个全局热键，看有没有被别的 app 抢走
        if CommandLine.arguments.contains("--hotkey-check") {
            NSApplication.shared.setActivationPolicy(.prohibited)
            AppDelegate().debugRegisterHotKeys()
            exit(0)
        }

        // 调试：启动后直接打开浏览器窗口，6 秒后打印窗口状态并退出（验证接线，不需要屏幕录制权限）
        if CommandLine.arguments.contains("--browser-check") {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            app.delegate = delegate
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                delegate.openBrowser()
            }
            // 再按一次 ⌥⌘B = 关窗，检查激活策略有没有退回菜单栏模式
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                delegate.openBrowser()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) {
                let visible = NSApp.windows.filter { $0.isVisible }
                    .map { "\($0.title)[\(Int($0.frame.width))x\(Int($0.frame.height))]" }
                print("policy=\(NSApp.activationPolicy().rawValue)  visible=\(visible)")
                print("screenshotException=\(OwnedWindows.browser)")
                exit(0)
            }
            app.run()
            exit(0)
        }

        // 调试：只测单实例锁，不建任何 UI（不会往菜单栏挂图标）
        if CommandLine.arguments.contains("--lock-test") {
            let got = delegate.acquireSingleInstanceLock()
            print(got ? "获得锁：本实例是唯一实例" : "锁已被占用：已有实例在运行")
            if got { Thread.sleep(forTimeInterval: 3) }   // 留窗口给并发测试
            exit(got ? 0 : 1)
        }

        let app = NSApplication.shared
        guard delegate.acquireSingleInstanceLock() else {
            FileHandle.standardError.write(
                "Good-tools 已经在运行，本实例直接退出（不会出现第二个菜单栏图标）\n"
                    .data(using: .utf8)!)
            exit(0)
        }
        app.delegate = delegate
        app.run()
    }
}

/// 造一张假的「桌面截图」，只为离屏预览覆盖层排版用（不需要屏幕录制权限）
func makeDummyScreenshot(size: NSSize) -> CGImage? {
    let image = NSImage(size: size, flipped: false) { rect in
        let gradient = NSGradient(colors: [NSColor(calibratedRed: 0.16, green: 0.20, blue: 0.30, alpha: 1),
                                           NSColor(calibratedRed: 0.31, green: 0.24, blue: 0.37, alpha: 1)])
        gradient?.draw(in: rect, angle: -35)

        let window = NSRect(x: 120, y: 80, width: rect.width - 240, height: rect.height - 160)
        NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
        NSBezierPath(roundedRect: window, xRadius: 10, yRadius: 10).fill()
        NSColor(calibratedWhite: 0.86, alpha: 1).setFill()
        NSRect(x: window.minX, y: window.maxY - 34, width: window.width, height: 34).fill()

        NSColor(calibratedWhite: 0.74, alpha: 1).setFill()
        for i in 0..<7 {
            let width = window.width * (i % 3 == 0 ? 0.72 : 0.52)
            NSRect(x: window.minX + 26,
                   y: window.maxY - 74 - CGFloat(i) * 26,
                   width: width, height: 9).fill()
        }

        let text = "预览用合成桌面 \(Int(size.width))×\(Int(size.height))"
        text.draw(at: NSPoint(x: 22, y: 22), withAttributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.75)
        ])
        return true
    }
    return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
}

/// 生成 <base>-dark.png / <base>-light.png
func renderIconPreview(to base: String) {
    let scale: CGFloat = 8
    let fills: [Double] = [0, 0.2, 0.5, 0.8, 1.0]
    let levels = [1, 4]          // 白（正常）/ 红（swap 频繁读写或压力紧急）
    let iconSize = NSSize(width: 16, height: 11)
    let cell = NSSize(width: iconSize.width + 16, height: 24)
    let logical = NSSize(width: cell.width * CGFloat(fills.count) + 12,
                         height: cell.height * CGFloat(levels.count) + 12)

    NSApplication.shared.setActivationPolicy(.prohibited)

    for (suffix, appearanceName, bg) in [("dark", NSAppearance.Name.darkAqua, NSColor(calibratedWhite: 0.13, alpha: 1)),
                                         ("light", NSAppearance.Name.aqua, NSColor(calibratedWhite: 0.94, alpha: 1))] {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(logical.width * scale),
                                         pixelsHigh: Int(logical.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { continue }
        rep.size = logical

        guard let appearance = NSAppearance(named: appearanceName) else { continue }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        appearance.performAsCurrentDrawingAppearance {
            bg.setFill()
            NSRect(origin: .zero, size: logical).fill()

            for (r, level) in levels.enumerated() {
                for (c, fill) in fills.enumerated() {
                    let image = makeGaugeImage(fill: fill, color: pressureColor(level))
                    let x = 6 + CGFloat(c) * cell.width + (cell.width - iconSize.width) / 2
                    let y = logical.height - 6 - CGFloat(r + 1) * cell.height
                        + (cell.height - iconSize.height) / 2
                    image.draw(in: NSRect(x: x, y: y, width: iconSize.width, height: iconSize.height))
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        let path = "\(base)-\(suffix).png"
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            print("→ \(path)  \(rep.pixelsWide)x\(rep.pixelsHigh)")
        }
    }
}
