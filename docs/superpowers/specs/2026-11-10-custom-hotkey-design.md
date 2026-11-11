# 自定义快捷键与快捷键测试

日期：2026-11-10
状态：已确认，待实现

## 背景

用户反馈：右 Option 无法唤起 freetalk，系统设置中已授权，但引导页仍显示未识别。排查确认根因不是热键被其他应用占用，而是：

1. freetalk 使用 ad-hoc 签名，每次构建或更新后 CDHash 变化。
2. macOS TCC 中 `kTCCServiceListenEvent` 的授权绑定了旧 CDHash。系统日志明确记录：
   `Failed to match existing code requirement ... cdhash H"f87b1fd0…" / H"46d02713…"`.
3. `GlobalHotkey.start()` 以 `CGPreflightListenEventAccess()` 为硬门槛，preflight 返回 false 时直接返回，事件 tap 从未创建，右 Option 因此完全无响应。
4. 权限页把这种情况显示为“尚未允许”，用户无法区分“没授权”和“开关已开但签名失配”。

同时，产品缺少自定义快捷键与验证快捷键是否生效的能力。

## 目标

- 修复“系统开关已开但快捷键不可用”的启动逻辑与权限提示。
- 支持自定义语音输入快捷键与会议快捷键。
- 提供不录音的按键识别测试，能区分权限问题、事件监听问题、绑定问题和快捷键被占用。
- 本地构建使用稳定代码签名身份，避免每次重建后重复授权。

## 非目标

- 不做完整录音链路测试（仍保留现有“5 秒后测试输入”）。
- 不改云端、转写、会议内容的处理逻辑。
- 不做 Apple 公证或 Developer ID 分发。

## 1. 事件监听与权限模型

### GlobalHotkey

- `start()` 直接尝试 `CGEvent.tapCreate`，以 `tap != nil` 作为唯一真实状态；不再用 `CGPreflightListenEventAccess()` 提前返回。
- 创建失败时记录可读的 `failure`：
  - 辅助功能与输入监控都不可用：需要系统权限。
  - 辅助功能不可用：活动事件 tap 需要辅助功能。
  - 辅助功能可用但 tap 仍失败：输入监控授权记录可能已失效，提示移除后重新添加 freetalk。
  - 其他：系统未允许创建事件监听。
- 重试：启动、应用激活、手动“重新连接”立即尝试；后台每 5 秒最多重试一次。
- `stop()` 释放 tap，清空状态与测试回调。

### 权限状态

- `shortcutReady = shortcutEnabled && shortcutActive`，不再要求输入监控 preflight 通过。
- 输入监控行状态：
  - 快捷键关闭：`快捷键未启用`。
  - tap 已创建：`已就绪 · 快捷键可用`（以系统实际创建的监听为准，不再看 preflight）。
  - tap 未创建、辅助功能可用、preflight 为 false：`系统开关可能已打开，但授权记录已失效`，按钮打开输入监控设置。
  - 其余：`尚未允许` 或 `权限已允许，快捷键尚未连接` + 重新连接。
- 权限页显示“事件监听：已连接 / 未连接（原因）”。

## 2. 快捷键数据模型

```swift
enum HotkeyModifier: Int, Codable, CaseIterable {
    case leftCommand = 55, rightCommand = 54
    case leftShift = 56, rightShift = 60
    case leftOption = 58, rightOption = 61
    case leftControl = 59, rightControl = 62
    case function = 63
}

struct HotkeyBinding: Codable, Equatable {
    enum Trigger: Codable, Equatable {
        case modifierTap(HotkeyModifier)
        case chord(keyCode: Int, modifiers: [HotkeyModifier])
    }
    var trigger: Trigger
}
```

- 默认语音输入：`modifierTap(.rightOption)`。
- 默认会议：`chord(46, [.rightOption])`（右 Option + M）。
- 单修饰键：左右 Option / Command / Shift / Control、Fn。
- 组合键：主键码 + 物理修饰键集合，区分左右。
- 持久化：`UserDefaults` 的 `hotkeyBindingV1`、`meetingBindingV1`、`meetingFollowsMainV1`，JSON 编码。
- 会议键默认跟随主修饰键 + M；主键为组合键时回退为右 Option + M；手动录制后 `meetingFollowsMainV1 = false`。

### 匹配规则

- 单修饰键：按下目标修饰键后 0.45 秒内松开，期间没有其他按键、没有其他修饰键，触发一次。
- 组合键：主键按下时，当前物理修饰键集合与绑定完全一致，触发一次；长按重复不重复触发；主键 keyUp 被消费。
- 左/右修饰键通过物理 keyCode 与 CGEvent device bit 双重判断；Fn 通过 keyCode 63 与 `maskSecondaryFn` 判断。
- Esc 仍用于取消录音，但仅在无修饰键时生效。

## 3. 设置界面

设置 → 语音输入 → 新增“快捷键”卡片：

- `语音输入：[右 Option]`，点击进入录制。
- `会议录音：[右 Option + M]`，点击进入录制。
- `会议键跟随语音键` 复选框。
- `[测试快捷键] [恢复默认]`。
- 启用/禁用全局快捷键的复选框保留。
- 录制状态与校验错误显示在同一卡片内。

录制规则：

- 点击按钮后进入录制，按钮标题变为“请按下快捷键…”。
- 修饰键轻按在松开时确认；按下其他键则录制组合键。
- Esc 取消录制。
- 拒绝：无修饰键的字母/数字、单独 Esc、与另一快捷键相同。
- 警告但不阻止：Cmd+Space、Ctrl+Space、Cmd+Tab 等已知系统组合；单独修饰键可能与输入法冲突。

## 4. 测试功能

点击“测试快捷键”后进入 8 秒监听，不录音、不插入文字：

| 情况 | 结果 |
| --- | --- |
| 事件 tap 未连接 | `监听未启动：<原因>`，并提供打开对应权限页的入口 |
| 收到事件但不匹配 | `监听正常：收到「M」，但未匹配当前快捷键` |
| 匹配成功 | `✓ 已收到：右 Option（0.12 秒）`，播放提示音 |
| 8 秒无事件 | `未收到按键：可能被其他应用占用，或权限已失效` |

测试期间抑制正常的开始/结束录音与会议动作。非匹配事件提示做 0.5 秒节流，避免刷屏。

## 5. 稳定本地签名

- 新增 `scripts/setup-local-signing.sh`：
  - 检查 `freetalk Local Signing` 是否已存在。
  - 用 openssl 生成带 `codeSigning` EKU 的自签名证书与私钥。
  - 导入登录钥匙串，`security add-trusted-cert -r trustRoot` 信任。
  - 输出使用说明。
- `scripts/build.sh` 在未显式设置 `FREETALK_SIGNING_IDENTITY` 时，若检测到该身份则自动使用。
- 已验证：重建后 designated requirement 稳定为
  `identifier "io.github.zacklinkk.freetalk" and certificate leaf = H"<证书哈希>"`，
  TCC 授权可跨构建保留。
- 切换到稳定签名后需要用户重新授权一次；之后本地重建不再失效。
- 从 GitHub 安装官方 ad-hoc 更新包后仍会失效一次，文档中说明。

## 6. 测试计划

- `tests/HotkeyTests.swift`：
  - 单修饰键触发、左右键区分、长按取消、其他按键/修饰键取消。
  - 组合键匹配、额外修饰键不匹配、重复按键不重复触发、keyUp 消费。
  - 会议键跟随主键；组合键主键时回退右 Option + M。
  - `HotkeyBinding` JSON 往返。
- `tests/PermissionTests.swift`：
  - tap 就绪、权限缺失、签名失效诊断、快捷键关闭、重新连接。
- 全量 `scripts/test.sh`。
- 真机验证：录制新快捷键 → 测试收到 → 实际录音 → 会议键 → 重建后权限仍保留。

## 风险与说明

- 活动事件 tap 的实际权限要求以 `CGEvent.tapCreate` 返回值为准，避免继续依赖 preflight 推断。
- 组合键与系统快捷键冲突无法完全自动检测；测试功能会明确区分“没收到事件”和“收到但不匹配”。
- 稳定签名只作用于本地构建；官方发布仍为 ad-hoc，直到引入 Developer ID。
