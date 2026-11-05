import AppKit
import AVFoundation
import ApplicationServices

enum VoicePermission: Int, CaseIterable {
    case microphone, accessibility, inputMonitoring
    var title: String {
        switch self {
        case .microphone: return "麦克风 · 听见你的声音"
        case .accessibility: return "辅助功能 · 把文字写入输入框"
        case .inputMonitoring: return "输入监控 · 使用右 Option"
        }
    }
    var instructions: String {
        switch self {
        case .microphone: return "首次点击后，在系统弹窗选择“允许”。曾拒绝过时：\n系统设置 → 隐私与安全 → 麦克风 → 打开 freetalk。"
        case .accessibility: return "系统设置 → 隐私与安全 → 辅助功能 → 打开 freetalk。\n用于读取当前输入位置并写入草稿，不会自动发送。"
        case .inputMonitoring: return "系统设置 → 隐私与安全 → 输入监控 → 打开 freetalk。\n用于检测右 Option；不启用时，也可以点击按钮录音。"
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
    static func current(shortcutActive: Bool) -> Self {
        Self(microphone:AVCaptureDevice.authorizationStatus(for:.audio),accessibility:AXIsProcessTrusted(),
             inputMonitoring:CGPreflightListenEventAccess(),
             shortcutEnabled:UserDefaults.standard.object(forKey:"shortcutEnabled") as? Bool != false,
             shortcutActive:shortcutActive)
    }
    var microphoneAllowed: Bool { microphone == .authorized }
    var canInsert: Bool { microphoneAllowed && accessibility }
    var shortcutReady: Bool { inputMonitoring && shortcutEnabled && shortcutActive }
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
            if !inputMonitoring { return Row(status:"尚未允许",button:"打开输入监控设置",ready:false,enabled:true) }
            if !shortcutEnabled { return Row(status:"权限已允许，快捷键未启用",button:"启用右 Option",ready:false,enabled:true) }
            if !shortcutActive { return Row(status:"权限已允许，快捷键尚未连接",button:"重新连接快捷键",ready:false,enabled:true) }
            return Row(status:"已允许 · 右 Option 可用",button:"已就绪",ready:true,enabled:false)
        }
    }
}
