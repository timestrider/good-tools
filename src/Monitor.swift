//  Good-tools · 系统监控（内存压力 / swap / 移动硬盘温度）

import Cocoa
import Darwin

// MARK: - 采样

struct MemSnapshot {
    var levelCode: Int          // 1 = 正常, 2 = 警告, 4 = 紧急
    var levelName: String
    var total: UInt64
    var used: UInt64
    var appMemory: UInt64
    var wired: UInt64
    var compressed: UInt64
    var swapUsed: UInt64
    var swapTotal: UInt64
    var swapInPages: UInt64      // 开机以来累计换入页数
    var swapOutPages: UInt64     // 开机以来累计换出页数

    var availablePct: Int {
        guard total > 0 else { return 0 }
        let pct = Double(total - min(used, total)) / Double(total) * 100.0
        return max(0, min(100, Int(pct.rounded())))
    }

    /// swap 占用比（0~1）。图标里点亮的格数由它决定。
    var swapRatio: Double {
        guard swapTotal > 0 else { return 0 }
        return min(1.0, Double(swapUsed) / Double(swapTotal))
    }
}

enum Sampler {
    /// mach_host_self() 每次调用都会多持有一个 send right，缓存一次即可。
    private static let hostPort: mach_port_t = mach_host_self()

    static func pageSize() -> UInt64 { UInt64(sysconf(_SC_PAGESIZE)) }

    static func sysctlInt32(_ name: String) -> Int32 {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return -1 }
        return value
    }

    static func swapUsage() -> (used: UInt64, total: UInt64) {
        var xsw = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &xsw, &size, nil, 0) == 0 else { return (0, 0) }
        return (xsw.xsu_used, xsw.xsu_total)
    }

    static func vmStatistics() -> vm_statistics64_data_t? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let kr = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(hostPort, HOST_VM_INFO64, intPtr, &count)
            }
        }
        return kr == KERN_SUCCESS ? stats : nil
    }

    static func sample() -> MemSnapshot? {
        guard let vm = vmStatistics() else { return nil }

        let page = pageSize()
        let total = UInt64(ProcessInfo.processInfo.physicalMemory)

        let wired = UInt64(vm.wire_count) * page
        let compressed = UInt64(vm.compressor_page_count) * page

        // Activity Monitor 的「已用内存」≈ App 内存 + Wired + 压缩
        // App 内存 = internal - purgeable
        let internalPages = UInt64(vm.internal_page_count)
        let purgeablePages = UInt64(vm.purgeable_count)
        let appPages = internalPages > purgeablePages ? internalPages - purgeablePages : 0
        let appMemory = appPages * page

        let used = appMemory + wired + compressed

        let level = sysctlInt32("kern.memorystatus_vm_pressure_level")
        let levelName: String
        switch level {
        case 1:  levelName = "正常"
        case 2:  levelName = "警告"
        case 4:  levelName = "紧急"
        default: levelName = "未知"
        }

        let swap = swapUsage()

        return MemSnapshot(
            levelCode: Int(level),
            levelName: levelName,
            total: total,
            used: used,
            appMemory: appMemory,
            wired: wired,
            compressed: compressed,
            swapUsed: swap.used,
            swapTotal: swap.total,
            swapInPages: vm.swapins,
            swapOutPages: vm.swapouts
        )
    }
}

// MARK: - 移动硬盘温度

/// 一块外置物理盘的温度快照。
///
/// 温度优先走 `diskutil info -plist`：不需要 root、不用装第三方工具。
/// 键是 `SMARTDeviceSpecificKeysMayVaryNotGuaranteed.TEMPERATURE`，值是**开尔文**
/// （实测 313 → 40 ℃，与 `smartctl` 报的 40 Celsius 对得上），所以要减 273。
/// 拿不到时退回 `smartctl -a -j`（顺带能读到厂商临界温度）；两边都失败就记一条原因。
struct DriveTemp {
    var device: String          // "disk6"
    var mediaName: String
    var sizeBytes: UInt64
    var celsius: Int?
    var vendorLimit: Int?       // 厂商临界温度（℃），只有 smartctl 那条路读得到
    var missing: String?        // 温度读不到时的原因，直接显示在菜单里

    var displayName: String { mediaName.isEmpty ? device : mediaName }
}

/// 后台按固定间隔采外置盘温度。
/// 温度不是秒级变化，30 s 一拍足够；也避免频繁叫醒休眠中的盘。
/// 采样永远在串行队列里跑，主线程只读 `drives` 快照。
final class DriveTempReader {

    static let shared = DriveTempReader()

    private let queue = DispatchQueue(label: "local.vincent.mempressure.disk-temp",
                                      qos: .utility)
    private var busy = false
    private var lastAt: Date?

    private(set) var drives: [DriveTemp] = []
    private(set) var lastError: String?

    /// 采样间隔（秒）
    let interval: TimeInterval = 30

    /// 主线程调用。到点才真的去采，`then` 在结果落定后回到主线程执行。
    func refreshIfStale(force: Bool = false, then: (() -> Void)? = nil) {
        if busy { return }
        if !force, let t = lastAt, Date().timeIntervalSince(t) < interval { return }
        busy = true
        lastAt = Date()
        queue.async { [weak self] in
            let result = DriveTempReader.probe()
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                self.drives = result.drives
                self.lastError = result.error
                then?()
            }
        }
    }

    // MARK: 探测

    /// 枚举外置物理盘并读温度。全程只调系统自带命令。
    static func probe() -> (drives: [DriveTemp], error: String?) {
        guard
            let listData = run("/usr/sbin/diskutil", ["list", "-plist", "external"]),
            let list = (try? PropertyListSerialization.propertyList(from: listData,
                                                                     format: nil)) as? [String: Any],
            let entries = list["AllDisksAndPartitions"] as? [[String: Any]]
        else {
            return ([], "diskutil list 调用失败")
        }

        var out: [DriveTemp] = []
        for entry in entries {
            guard let dev = entry["DeviceIdentifier"] as? String, isWholeDisk(dev) else { continue }
            guard
                let infoData = run("/usr/sbin/diskutil", ["info", "-plist", dev]),
                let info = (try? PropertyListSerialization.propertyList(from: infoData,
                                                                         format: nil)) as? [String: Any]
            else { continue }

            // 排除磁盘镜像（ComfyRAM 之类的 ram disk）与合成卷
            if (info["VirtualOrPhysical"] as? String) != "Physical" { continue }
            // 只要外置的
            if (info["Internal"] as? Bool) == true { continue }

            let name = (info["MediaName"] as? String) ?? ""
            let size = (info["Size"] as? NSNumber)?.uint64Value ?? 0

            var celsius: Int?
            var limit: Int?
            var missing: String?

            // ① diskutil：开尔文 → 摄氏
            if let sk = info["SMARTDeviceSpecificKeysMayVaryNotGuaranteed"] as? [String: Any],
               let raw = (sk["TEMPERATURE"] as? NSNumber)?.intValue, raw > 0 {
                celsius = raw > 200 ? raw - 273 : raw     // 有的桥直接给摄氏，做个兜底判断
            }

            // ② 兜底：smartctl（休眠的盘用 -n standby 直接放过，绝不叫醒它）
            if celsius == nil {
                let sc = smartctl(dev: dev)
                if let c = sc?.celsius { celsius = c; limit = sc?.limit }
                else if let why = sc?.missing { missing = why }
            }

            if celsius == nil, missing == nil { missing = "桥接芯片不报温度" }

            out.append(DriveTemp(device: dev, mediaName: name, sizeBytes: size,
                                 celsius: celsius, vendorLimit: limit, missing: missing))
        }
        return (out, nil)
    }

    /// 读一块盘的 SMART（NVMe / SATA 都交给 smartctl 自己判断）。
    /// 返回 nil 表示机器上没装 smartctl。
    private static func smartctl(dev: String) -> (celsius: Int?, limit: Int?, missing: String?)? {
        let candidates = ["/opt/homebrew/bin/smartctl",
                          "/usr/local/bin/smartctl",
                          "/usr/bin/smartctl"]
        guard let bin = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { return nil }

        guard let data = run(bin, ["-a", "-j", "-n", "standby,0", "/dev/\(dev)"]),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return (nil, nil, "smartctl 无输出") }

        let temp = obj["temperature"] as? [String: Any]
        let celsius = (temp?["current"] as? NSNumber)?.intValue
        let limit = (temp?["critical_limit_max"] as? NSNumber)?.intValue

        var missing: String?
        if celsius == nil {
            let messages = ((obj["smartctl"] as? [String: Any])?["messages"] as? [[String: Any]]) ?? []
            let text = messages.compactMap { $0["string"] as? String }.joined(separator: " / ")
            if text.contains("STANDBY") || text.contains("standby") {
                missing = "休眠中"
            } else if text.contains("Permission denied") || text.contains("permission") {
                missing = "需要 root 权限"
            } else if !text.isEmpty {
                missing = "SMART 读不到（桥接不支持）"
            }
        }
        return (celsius, limit, missing)
    }

    private static func isWholeDisk(_ dev: String) -> Bool {
        guard dev.hasPrefix("disk") else { return false }
        let rest = dev.dropFirst(4)
        return !rest.isEmpty && rest.allSatisfy { $0.isNumber }
    }

    /// 跑一个短命令拿 stdout。4 s 不返回就杀掉，绝不把采样队列堵死。
    private static func run(_ path: String, _ args: [String], timeout: TimeInterval = 4) -> Data? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()          // 丢掉 stderr，别让它写满缓冲

        do { try process.run() } catch { return nil }

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        return data.isEmpty ? nil : data
    }
}

// MARK: - 格式化

func fmtBytes(_ bytes: UInt64) -> String {
    let gb = Double(bytes) / 1_073_741_824.0
    if gb >= 1 { return String(format: "%.1f GB", gb) }
    let mb = Double(bytes) / 1_048_576.0
    if mb >= 1 { return String(format: "%.0f MB", mb) }
    return "0 MB"
}

/// 菜单栏上尽量短
func fmtCompact(_ bytes: UInt64) -> String {
    let gb = Double(bytes) / 1_073_741_824.0
    if gb >= 10 { return String(format: "%.0fG", gb) }
    if gb >= 1 { return String(format: "%.1fG", gb) }
    return String(format: "%.0fM", Double(bytes) / 1_048_576.0)
}

/// 菜单栏专用的 swap 数字：< 1 GB 用 MB 整数，>= 1 GB 一律保留一位小数。
/// 不用 fmtCompact 的原因：它 >= 10 GB 会取整，20.4 GB 会显示成 "20G"，
/// 而 swap 涨到 20 GB 时用量和容量几乎贴着，取整后两数完全一样，看不出差别。
func fmtSwap(_ bytes: UInt64) -> String {
    let mb = Double(bytes) / 1_048_576.0
    if mb < 1000 { return String(format: "%.0fM", mb) }
    let text = String(format: "%.1f", mb / 1024.0)
    // 整数 GB 去掉 ".0"：1.0G → 1G，20.0G → 20G；非整数保留一位（20.4G）
    return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + "G"
}

/// 白 / 蓝 / 红 三态。
/// 「白」用 labelColor：深色菜单栏下就是白色，浅色下自动变黑 —— 否则纯白在浅色
/// 菜单栏上完全看不见（同一个图标要在两种外观里都成立）。蓝、红是固定色。
func pressureColor(_ code: Int) -> NSColor {
    switch code {
    case 1:  return .labelColor
    case 2:  return .systemBlue
    case 4:  return .systemRed
    default: return .systemGray
    }
}

/// 内存压力图样：上升阶梯状的 5 根柱子。
///   · 颜色 = 压力等级（白 = 正常 / 蓝 = 警告 / 红 = 紧急）
///   · 亮起的格数 = swap 占用比（0 格全暗，只留有 25% 透明度的底座）
func makeGaugeImage(fill: Double,
                    color: NSColor,
                    barCount: Int = 5,
                    barWidth: CGFloat = 2.0,
                    gap: CGFloat = 1.4,
                    maxHeight: CGFloat = 11.0) -> NSImage {
    let width = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * gap
    let image = NSImage(size: NSSize(width: width, height: maxHeight), flipped: false) { _ in
        var lit = Int((fill * Double(barCount)).rounded(.up))
        if fill > 0 { lit = max(1, lit) }
        lit = min(barCount, lit)
        for i in 0..<barCount {
            let h = maxHeight * (0.40 + 0.60 * CGFloat(i) / CGFloat(barCount - 1))
            let rect = NSRect(x: CGFloat(i) * (barWidth + gap), y: 0, width: barWidth, height: h)
            let path = NSBezierPath(roundedRect: rect, xRadius: 0.8, yRadius: 0.8)
            color.withAlphaComponent(i < lit ? 1.0 : 0.25).setFill()
            path.fill()
        }
        return true
    }
    image.isTemplate = false
    return image
}

