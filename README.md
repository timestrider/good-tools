# Good-tools

菜单栏常驻的小工具箱，一个 app 装下三件事。

> **仅支持 Apple Silicon（M 系列芯片）**，不支持 Intel Mac。


| 功能 | 入口 | 说明 |
|---|---|---|
| 内存 / swap 监控 | 菜单栏图样 | 压力等级、swap 用量与读写速率、内存分项、移动硬盘温度，过热变红 + 弹窗 |
| 截图 | `⌃⌘A` | 整屏压暗 → 拖选 / 单击吸附窗口 → 松开即进剪贴板 |
| 浏览器 | `⌥⌘B` | 多 UA 一键切换 + 收藏夹的轻量 WebView 浏览器，独立窗口 |

菜单栏图样上的数字是 `已用 swap / 分区容量`，格数 = swap 占用比；红 = swap 频繁换页、内存压力紧急、或移动硬盘过热。

## 构建 / 安装

```bash
./build.sh              # 编到 ~/Applications/Good-tools.app 并启动
NO_OPEN=1 ./build.sh    # 只编不启动
APP=/tmp/X.app ./build.sh   # 编到别处（调试用）
```

只需 Command Line Tools，无需完整 Xcode。`build.sh` 会先收掉正在跑的 GoodTools / 旧版 MemPressure（否则热键和菜单栏图标会打架）。

## 首次使用要点

1. **屏幕录制权限**：第一次按 `⌃⌘A` 会弹授权。菜单里也有一行红字「⚠︎ 需要「屏幕录制」权限」，点它直接跳系统设置。授权后需要重启一次 app。
2. 授权绑的是 **bundle id**（`local.vincent.goodtools`），重编多少次都不会掉权限 —— `build.sh` 里钉死了 `designated => identifier`，不含 cdhash。
3. 通知权限：第一次触发告警时才询问，拒绝也不影响菜单显示。

## 快捷键

| 键 | 作用 |
|---|---|
| `⌃⌘A` | 截图（截图中再按一次 = 取消） |
| `⌥⌘B` | 开 / 关浏览器窗口 |
| `⌘L` `⌘R` `⌘[` `⌘]` `⌘D` `⌘U` | 浏览器：地址栏 / 刷新 / 后退 / 前进 / 收藏 / 查看当前 UA |
| `⌘+` `⌘-` `⌘0` | 浏览器缩放 |
| `⌘,` | 设定窗口 |
| `Esc` / 右键 | 取消截图 |

## 截图交互

- 拖动 = 自由框选；松开即复制到剪贴板（`⌘V` 直接粘）
- 鼠标停在某个窗口上会高亮整块（蓝框 + `窗口 宽 × 高　点击选中`），**单击** = 整块窗口
- 窗口里按住拖 = 仍然自由框选，不冲突
- `Enter` 复制当前选区，`Esc` / 右键 / 再按 `⌃⌘A` 取消
- 截完把焦点还给原来的 app，接着粘贴顺手

## 实现要点

- 抓屏：ScreenCaptureKit `SCScreenshotManager`（`CGWindowListCreateImage` 已废弃，无权限时只返回黑图）。尺寸用 `CGDisplayPixelsWide/High` —— `SCDisplay.width` 是**点**不是像素，拿它当像素会按半分辨率抓，5K 屏上明显发糊。
- 覆盖层：每块屏一个 borderless `NSWindow`，level 用 `CGShieldingWindowLevel()`，`collectionBehavior` 跟着所有 Space。
- 窗口吸附：`CGWindowListCopyWindowInfo`（顺序**保证** front-to-back），`layer == 0` 一条滤掉菜单栏 / Dock / 壁纸。
- 抓屏时排除自身 app（菜单栏图标不入镜），但**按 window id 把浏览器窗口放回来** —— 截自己正在看的网页是正经需求。
- 热键：Carbon `RegisterEventHotKey`，**不需要「辅助功能」权限**。多个热键共用一个 handler，按 `EventHotKeyID.id` 分发。
- 浏览器窗口：菜单栏 app 平时是 `.accessory`；开浏览器时切 `.regular`（有 Dock 图标与菜单栏，`⌘L` 等才生效），关窗切回 `.accessory`，关窗不退出、页面保留（只暂停里面的音视频）。

## 目录

```
Good-tools/
├── build.sh                 # 编译 + 组装 .app + 钉死 DR 签名
├── Resources/Info.plist     # LSUIElement + NSAllowsArbitraryLoads
├── Resources/AppIcon.icns
└── src/
    ├── Entry.swift          # @main 入口 + 一堆调试开关
    ├── AppDelegate.swift    # 状态栏图标 / 菜单 / 采样循环 / 主菜单
    ├── Monitor.swift        # 内存、swap、移动硬盘温度采样与格式化
    ├── Notifier.swift       # 用户通知
    ├── Snapshot.swift       # 截图状态机 + 覆盖窗 + 框选视图
    ├── Settings.swift       # 设定窗口
    ├── HotKeys.swift        # 全局热键
    ├── BrowserWindow.swift  # 浏览器窗口与激活策略切换
    └── Browser.swift        # WebView、UA 切换、收藏夹
```

## 调试开关

```bash
GoodTools --dump                     # 打一行内存/swap/盘温快照
GoodTools --menu-dump                # 构建菜单并打印每行（含红色标记）
GoodTools --disk-dump [阈值]          # 只采外置盘温度
GoodTools --hotkey-check             # 试注册 ⌃⌘A / ⌥⌘B，打印成没成
GoodTools --browser-check            # 开浏览器窗口再关掉，打印窗口与激活策略
GoodTools --settings-preview /tmp/s [light|dark]   # 设定页渲染成 PNG
GoodTools --snapshot-preview /tmp/p  # 用合成桌面渲染覆盖层（hint / sel / window 三张）
GoodTools --snapshot-capture /tmp/x.png            # 真抓一次全屏（要屏幕录制权限）
GoodTools --icon-preview /tmp/i      # 菜单栏图标各状态 8 倍放大图
GoodTools --test-notify              # 发一条测试通知
GoodTools --lock-test                # 只测单实例锁
```

## 已知边界

- 全屏 app（视频 / 游戏）盖住下面所有窗口时，吸附只能选到最上面那个，和微信截图一致。
- `--snapshot-preview` 用合成图离屏渲染，不需要屏幕录制权限；但它的绘制路径和真机一致，改完 UI 先用它做回归。
- 浏览器是 WKWebView，不是 Chromium：某些依赖特定内核的站点可能不兼容。
