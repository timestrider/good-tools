//  Good-tools · 浏览器窗口
//
//  菜单栏 app 里按需开窗：关窗不退出，下次从菜单或 ⌥⌘B 打开还是原来那个页面。
//  开窗期间把激活策略切成 .regular（Dock 图标 + 菜单栏快捷键可用），关窗后切回 .accessory。

import Cocoa

final class BrowserWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private var vc: BrowserViewController?
    private var started = false

    private static let frameAutosaveName = "GoodToolsBrowserWindow"

    var isVisible: Bool { window?.isVisible ?? false }

    /// 菜单/热键入口：没开过就建，已开着就切到最前（不重复 load 首页）
    func show() {
        if window == nil { build() }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)

        if started {
            vc?.focusPage()
        } else {
            started = true
            vc?.start()
        }
        syncOwnedWindows()
    }

    /// ⌥⌘B：开着就关，关着就开
    func toggle() {
        if isVisible { window?.close() } else { show() }
    }

    private func build() {
        let vc = BrowserViewController()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered,
                         defer: false)
        w.title = "Good-tools"
        w.minSize = NSSize(width: 660, height: 440)
        w.contentViewController = vc
        // 注意顺序：赋 contentViewController 会把窗口缩成内容视图的尺寸（loadView 里是零尺寸），
        // 所以尺寸和位置必须在它之后设，否则一开窗就只剩 minSize 那么大。
        if !w.setFrameUsingName(Self.frameAutosaveName) {
            w.setContentSize(NSSize(width: 1200, height: 800))
            w.center()
        }
        w.setFrameAutosaveName(Self.frameAutosaveName)
        w.isReleasedWhenClosed = false          // 关窗只是收起来，对象留着下次复用
        w.delegate = self

        self.window = w
        self.vc = vc
    }

    func windowWillClose(_ notification: Notification) {
        vc?.suspendMedia()          // 关窗了就别在后台偷偷播视频
        OwnedWindows.browser = []
        // 关完窗不该留一个没窗口的 Dock 图标（设定窗还开着就不切）。
        // 只看能当主窗口的窗口：状态栏图标那些 91×30 的辅助窗也算 isVisible，
        // 用 isVisible 判断会永远切不回去。
        DispatchQueue.main.async { [weak self] in
            let stillShowing = NSApp.windows.contains {
                $0.isVisible && $0 !== self?.window && $0.canBecomeMain
            }
            if !stillShowing { NSApp.setActivationPolicy(.accessory) }
        }
    }

    /// 浏览器窗口要留在截图画面里（排除自身 app 时按 window id 放回来）
    private func syncOwnedWindows() {
        guard let w = window, w.isVisible else {
            OwnedWindows.browser = []
            return
        }
        OwnedWindows.browser = [CGWindowID(w.windowNumber)]
    }
}
