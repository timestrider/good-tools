//  Good-tools · 全局热键
//
//  用 Carbon 的 RegisterEventHotKey：不需要「辅助功能」权限（NSEvent 全局监听才需要）。
//  所有热键共用同一个 C handler，按 EventHotKeyID.id 分发给各自的闭包。

import Cocoa
import Carbon.HIToolbox

final class GlobalHotKey {
    static let shared = GlobalHotKey()

    enum Action: UInt32 {
        case snapshot = 1       // ⌃⌘A
        case browser = 2        // ⌥⌘B
    }

    /// Carbon 的 signature，'GOOD'
    fileprivate static let signature: OSType = 0x474F4F44

    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var handlerInstalled = false

    @discardableResult
    func register(_ action: Action,
                  keyCode: Int,
                  modifiers: Int,
                  handler: @escaping () -> Void) -> Bool {
        installHandlerIfNeeded()
        actions[action.rawValue] = handler

        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: action.rawValue)
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref { refs.append(ref) }
        return status == noErr
    }

    fileprivate func fire(_ id: UInt32) {
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
