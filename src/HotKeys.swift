//  Good-tools · 全局热键
//
//  用 Carbon 的 RegisterEventHotKey：不需要「辅助功能」权限（NSEvent 全局监听才需要）。
//  所有热键共用同一个 C handler，按 EventHotKeyID.id 分发给各自的闭包。

import Cocoa
import Carbon.HIToolbox

// MARK: - 组合键模型

/// 虚拟键码 + Carbon 修饰键掩码。虚拟键码跟键盘布局无关，存下来换布局也不会错位。
/// 持久化成一个字符串 "keyCode:modifiers"，读出来做范围校验，坏了就退回默认值。
struct HotKeyCombo: Equatable {

    var keyCode: Int
    var modifiers: Int

    static let snapshotDefault = HotKeyCombo(keyCode: Int(kVK_ANSI_A),
                                             modifiers: cmdKey | controlKey)
    static let browserDefault = HotKeyCombo(keyCode: Int(kVK_ANSI_B),
                                            modifiers: cmdKey | optionKey)

    private static let defaultsKey = "snapshotHotKey"

    var rawValue: String { "\(keyCode):\(modifiers)" }

    static func loadSnapshot() -> HotKeyCombo {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey) else {
            return snapshotDefault
        }
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let kc = Int(parts[0]), let mod = Int(parts[1]),
              (0..<128).contains(kc), mod > 0,
              !modifierOnlyKeyCodes.contains(kc) else { return snapshotDefault }
        return HotKeyCombo(keyCode: kc, modifiers: mod)
    }

    func saveSnapshot() {
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
    }

    /// 从一次真实按键取组合。要求至少一个修饰键，避免把裸按键注册成全局热键。
    static func from(event: NSEvent) -> HotKeyCombo? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mod = 0
        if flags.contains(.command) { mod |= cmdKey }
        if flags.contains(.control) { mod |= controlKey }
        if flags.contains(.option) { mod |= optionKey }
        if flags.contains(.shift) { mod |= shiftKey }
        guard mod != 0 else { return nil }
        let code = Int(event.keyCode)
        guard (0..<128).contains(code), !modifierOnlyKeyCodes.contains(code) else { return nil }
        return HotKeyCombo(keyCode: code, modifiers: mod)
    }

    /// 菜单和按钮上的显示文本。修饰键顺序按 Apple 习惯：⌃⌥⇧⌘。
    var displayText: String {
        var s = ""
        if modifiers & controlKey != 0 { s += "⌃" }
        if modifiers & optionKey  != 0 { s += "⌥" }
        if modifiers & shiftKey   != 0 { s += "⇧" }
        if modifiers & cmdKey     != 0 { s += "⌘" }
        return s + Self.keyName(keyCode)
    }

    private static let modifierOnlyKeyCodes: Set<Int> = [
        Int(kVK_Command), Int(kVK_Shift), Int(kVK_CapsLock), Int(kVK_Option),
        Int(kVK_Control), Int(kVK_RightShift), Int(kVK_RightOption),
        Int(kVK_RightControl), Int(kVK_Function)
    ]

    private static let keyNames: [Int: String] = {
        var m: [Int: String] = [
            Int(kVK_Space): "空格", Int(kVK_Return): "↩", Int(kVK_Tab): "⇥",
            Int(kVK_Delete): "⌫", Int(kVK_ForwardDelete): "⌦", Int(kVK_Escape): "Esc",
            Int(kVK_LeftArrow): "←", Int(kVK_RightArrow): "→",
            Int(kVK_UpArrow): "↑", Int(kVK_DownArrow): "↓",
            Int(kVK_Home): "Home", Int(kVK_End): "End",
            Int(kVK_PageUp): "PgUp", Int(kVK_PageDown): "PgDn"
        ]
        let named: [(Int, String)] = [
            (Int(kVK_ANSI_A), "A"), (Int(kVK_ANSI_B), "B"), (Int(kVK_ANSI_C), "C"),
            (Int(kVK_ANSI_D), "D"), (Int(kVK_ANSI_E), "E"), (Int(kVK_ANSI_F), "F"),
            (Int(kVK_ANSI_G), "G"), (Int(kVK_ANSI_H), "H"), (Int(kVK_ANSI_I), "I"),
            (Int(kVK_ANSI_J), "J"), (Int(kVK_ANSI_K), "K"), (Int(kVK_ANSI_L), "L"),
            (Int(kVK_ANSI_M), "M"), (Int(kVK_ANSI_N), "N"), (Int(kVK_ANSI_O), "O"),
            (Int(kVK_ANSI_P), "P"), (Int(kVK_ANSI_Q), "Q"), (Int(kVK_ANSI_R), "R"),
            (Int(kVK_ANSI_S), "S"), (Int(kVK_ANSI_T), "T"), (Int(kVK_ANSI_U), "U"),
            (Int(kVK_ANSI_V), "V"), (Int(kVK_ANSI_W), "W"), (Int(kVK_ANSI_X), "X"),
            (Int(kVK_ANSI_Y), "Y"), (Int(kVK_ANSI_Z), "Z"),
            (Int(kVK_ANSI_0), "0"), (Int(kVK_ANSI_1), "1"), (Int(kVK_ANSI_2), "2"),
            (Int(kVK_ANSI_3), "3"), (Int(kVK_ANSI_4), "4"), (Int(kVK_ANSI_5), "5"),
            (Int(kVK_ANSI_6), "6"), (Int(kVK_ANSI_7), "7"), (Int(kVK_ANSI_8), "8"),
            (Int(kVK_ANSI_9), "9"),
            (Int(kVK_ANSI_Minus), "-"), (Int(kVK_ANSI_Equal), "="),
            (Int(kVK_ANSI_Comma), ","), (Int(kVK_ANSI_Period), "."),
            (Int(kVK_ANSI_Slash), "/"), (Int(kVK_ANSI_Semicolon), ";"),
            (Int(kVK_ANSI_Quote), "'"), (Int(kVK_ANSI_LeftBracket), "["),
            (Int(kVK_ANSI_RightBracket), "]"), (Int(kVK_ANSI_Backslash), "\\"),
            (Int(kVK_ANSI_Grave), "`"),
            (Int(kVK_F1), "F1"), (Int(kVK_F2), "F2"), (Int(kVK_F3), "F3"),
            (Int(kVK_F4), "F4"), (Int(kVK_F5), "F5"), (Int(kVK_F6), "F6"),
            (Int(kVK_F7), "F7"), (Int(kVK_F8), "F8"), (Int(kVK_F9), "F9"),
            (Int(kVK_F10), "F10"), (Int(kVK_F11), "F11"), (Int(kVK_F12), "F12"),
            (Int(kVK_F13), "F13"), (Int(kVK_F14), "F14"), (Int(kVK_F15), "F15"),
            (Int(kVK_F16), "F16"), (Int(kVK_F17), "F17"), (Int(kVK_F18), "F18"),
            (Int(kVK_F19), "F19"), (Int(kVK_F20), "F20")
        ]
        for (code, name) in named { m[code] = name }
        return m
    }()

    private static func keyName(_ code: Int) -> String { keyNames[code] ?? "#\(code)" }
}

// MARK: - 注册中心

final class GlobalHotKey {
    static let shared = GlobalHotKey()

    enum Action: UInt32 {
        case snapshot = 1       // 默认 ⌃⌘A，可在设定页改
        case browser = 2        // ⌥⌘B
    }

    /// Carbon 的 signature，'GOOD'
    fileprivate static let signature: OSType = 0x474F4F44

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var handlerInstalled = false

    /// 录制快捷键时暂停分发：否则按下当前正在用的组合键会同时触发截图/浏览器。
    var isSuspended = false

    @discardableResult
    func register(_ action: Action,
                  keyCode: Int,
                  modifiers: Int,
                  handler: @escaping () -> Void) -> Bool {
        installHandlerIfNeeded()
        // 同一个 action 重注册前必须解绑旧的，否则 refs 里堆一堆失效引用，
        // 旧的 EventHotKeyRef 还占着组合键，新键会注册失败。
        unregister(action)

        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: action.rawValue)
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs[action.rawValue] = ref
        actions[action.rawValue] = handler
        return true
    }

    func unregister(_ action: Action) {
        if let ref = refs.removeValue(forKey: action.rawValue) {
            UnregisterEventHotKey(ref)
        }
        actions.removeValue(forKey: action.rawValue)
    }

    fileprivate func fire(_ id: UInt32) {
        guard !isSuspended else { return }
        actions[id]?()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard InstallEventHandler(GetApplicationEventTarget(), goodToolsHotKeyHandler,
                                  1, &spec, context, nil) == noErr else { return }
        handlerInstalled = true
    }
}

/// 必须是 C 函数（不能捕获上下文），所以对象指针从 userData 里取。
private func goodToolsHotKeyHandler(_ callRef: EventHandlerCallRef?,
                                    _ event: EventRef?,
                                    _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let err = GetEventParameter(event,
                                EventParamName(kEventParamDirectObject),
                                EventParamType(typeEventHotKeyID),
                                nil,
                                MemoryLayout<EventHotKeyID>.size,
                                nil,
                                &hotKeyID)
    guard err == noErr, hotKeyID.signature == GlobalHotKey.signature else {
        return OSStatus(eventNotHandledErr)
    }
    let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
    DispatchQueue.main.async { hotKey.fire(hotKeyID.id) }
    return noErr
}

// MARK: - 录制控件

/// 设定页里的快捷键按钮：点一下进入录制态，按下组合键提交，Esc 取消。
/// 录制期间全局热键暂停分发，免得"按新键"的瞬间先把旧功能触发一遍。
final class HotKeyRecorder: NSButton {

    var combo: HotKeyCombo { didSet { updateTitle() } }
    var onCommit: ((HotKeyCombo) -> Void)?
    var onCancel: (() -> Void)?

    private var recording = false

    init(combo: HotKeyCombo) {
        self.combo = combo
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(beginRecording)
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }

    @objc private func beginRecording() {
        recording = true
        GlobalHotKey.shared.isSuspended = true
        updateTitle()
        window?.makeFirstResponder(self)
        // makeFirstResponder 可能失败（窗口不是 key），这时别把热键一直挂起
        if window?.firstResponder !== self { finishRecording() }
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if Int(event.keyCode) == Int(kVK_Escape) {
            finishRecording()
            onCancel?()
            return
        }
        guard let newCombo = HotKeyCombo.from(event: event) else {
            NSSound.beep()          // 没带修饰键，不收
            return
        }
        finishRecording()
        onCommit?(newCombo)
    }

    override func resignFirstResponder() -> Bool {
        if recording {
            finishRecording()
            onCancel?()
        }
        return super.resignFirstResponder()
    }

    private func finishRecording() {
        recording = false
        GlobalHotKey.shared.isSuspended = false
        updateTitle()
    }

    private func updateTitle() {
        title = recording ? "按下组合键…（Esc 取消）" : combo.displayText
        toolTip = recording ? "" : "点击后按下新的组合键；至少带一个 ⌘ / ⌃ / ⌥ / ⇧"
    }
}
