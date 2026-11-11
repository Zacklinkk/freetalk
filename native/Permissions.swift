import AppKit
import AVFoundation
import ApplicationServices

enum VoicePermission: Int, CaseIterable {
    case microphone, accessibility, inputMonitoring
    var title: String {
        switch self {
        case .microphone: return "麦克风 · 听见你的声音"
        case .accessibility: return "辅助功能 · 把文字写入输入框"
        case .inputMonitoring: return "输入监控 · 使用全局快捷键"
        }
    }
    var instructions: String {
        switch self {
        case .microphone: return "首次点击后，在系统弹窗选择“允许”。曾拒绝过时：\n系统设置 → 隐私与安全 → 麦克风 → 打开 freetalk。"
        case .accessibility: return "系统设置 → 隐私与安全 → 辅助功能 → 打开 freetalk。\n用于读取当前输入位置并写入草稿，不会自动发送。\n若开关已打开但仍显示尚未允许，请移除后重新添加当前 freetalk.app。"
        case .inputMonitoring: return "系统设置 → 隐私与安全 → 输入监控 → 打开 freetalk。\n用于检测你设置的快捷键；不启用时，也可以点击按钮录音。\n若开关已打开但仍提示失效，请移除后重新添加当前 freetalk.app。"
        }
    }
    var settingsURL: URL {
        let pane: String
        switch self {
        case .microphone: pane = "Privacy_Microphone"
        case .accessibility: pane = "Privacy_Accessibility"
        case .inputMonitoring: pane = "Privacy_ListenEvent"
        }
        return URL(string:"x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }
}

struct VoicePermissions {
    let microphone: AVAuthorizationStatus
    let accessibility: Bool, inputMonitoring: Bool, shortcutEnabled: Bool, shortcutActive: Bool
    var shortcutFailure: String? = nil
    static func current(shortcutActive: Bool, shortcutFailure: String? = nil) -> Self {
        Self(microphone:AVCaptureDevice.authorizationStatus(for:.audio),accessibility:AXIsProcessTrusted(),
             inputMonitoring:CGPreflightListenEventAccess(),
             shortcutEnabled:UserDefaults.standard.object(forKey:"shortcutEnabled") as? Bool != false,
             shortcutActive:shortcutActive,shortcutFailure:shortcutFailure)
    }
    var microphoneAllowed: Bool { microphone == .authorized }
    var canInsert: Bool { microphoneAllowed && accessibility }
    // The event tap is the source of truth: macOS decides when the tap is
    // created, and a record left by an older signature makes the switch in
    // System Settings disagree with what this binary is actually granted.
    var shortcutReady: Bool { shortcutEnabled && shortcutActive }
    var canContinue: Bool { canInsert && (!shortcutEnabled || shortcutReady) }
    var needsGuidance: Bool { !canContinue }
    struct Row {
        let status: String, button: String
        let ready: Bool, enabled: Bool
    }
    func row(_ permission: VoicePermission) -> Row {
        switch permission {
        case .microphone:
            switch microphone {
            case .authorized: return Row(status:"已允许",button:"已允许",ready:true,enabled:false)
            case .notDetermined: return Row(status:"等待你的允许",button:"允许麦克风",ready:false,enabled:true)
            case .restricted: return Row(status:"被系统或设备管理策略限制，请联系设备管理员",button:"系统限制",ready:false,enabled:false)
            default: return Row(status:"尚未允许，请在系统设置中打开",button:"打开麦克风设置",ready:false,enabled:true)
            }
        case .accessibility:
            return Row(status:accessibility ? "已允许" : "尚未允许",button:accessibility ? "已允许" : "打开辅助功能设置",ready:accessibility,enabled:!accessibility)
        case .inputMonitoring:
            if !shortcutEnabled { return Row(status:"快捷键未启用",button:"启用快捷键",ready:false,enabled:true) }
            if shortcutActive { return Row(status:"已就绪 · 快捷键可用",button:"已就绪",ready:true,enabled:false) }
            if accessibility && !inputMonitoring {
                // Cannot tell "never enabled" from a stale record left by an
                // older signature, so give the steps for both.
                return Row(status:"未生效：请在输入监控中打开 freetalk；已打开仍无效时，移除后重新添加",button:"打开输入监控设置",ready:false,enabled:true)
            }
            if !inputMonitoring { return Row(status:"尚未允许",button:"打开输入监控设置",ready:false,enabled:true) }
            if let failure = shortcutFailure, !failure.isEmpty {
                return Row(status:"快捷键尚未连接：\(failure)",button:"重新连接快捷键",ready:false,enabled:true)
            }
            return Row(status:"权限已允许，快捷键尚未连接",button:"重新连接快捷键",ready:false,enabled:true)
        }
    }
}
