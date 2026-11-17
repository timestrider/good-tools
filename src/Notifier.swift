//  Good-tools · 通知

import Cocoa
import UserNotifications

// MARK: - 通知

/// 只负责把请求交给系统的 NotificationCenter。
/// 渲染（banner 动画、声音）全在系统进程里做，本进程只是发一个几十字节的 XPC 请求，
/// 所以"提醒"本身的开销可以忽略 —— 真正的成本在于**发得太频繁**，靠调用侧的冷却和每日上限控制。
final class Notifier: NSObject, UNUserNotificationCenterDelegate {

    static let shared = Notifier()

    private let center = UNUserNotificationCenter.current()

    func setup() {
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(title: String, body: String, sound: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)
        center.add(request, withCompletionHandler: nil)
    }

    func printStatus(label: String, alsoToFile path: String? = nil) {
        center.getNotificationSettings { settings in
            let names: [UNAuthorizationStatus: String] = [
                .notDetermined: "未询问", .denied: "被拒绝", .authorized: "已授权",
                .provisional: "临时授权"
            ]
            let line = "[\(label)] 通知权限：\(names[settings.authorizationStatus] ?? "未知(\(settings.authorizationStatus.rawValue))")"
            print(line)
            if let path {
                let text = line + "\n"
                if let handle = FileHandle(forWritingAtPath: path) {
                    handle.seekToEndOfFile()
                    handle.write(text.data(using: .utf8) ?? Data())
                    handle.closeFile()
                } else {
                    try? text.write(toFile: path, atomically: true, encoding: .utf8)
                }
            }
        }
    }

    /// 前台时也照常显示 banner（菜单栏 app 没有窗口，不实现这个可能什么都看不到）
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}

