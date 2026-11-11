import Foundation
import AVFoundation

@main struct PermissionTests {
    static func main() {
        let fresh = VoicePermissions(microphone:.notDetermined,accessibility:false,inputMonitoring:false,shortcutEnabled:true,shortcutActive:false)
        precondition(fresh.row(.microphone).button == "允许麦克风" && fresh.needsGuidance)
        let denied = VoicePermissions(microphone:.denied,accessibility:true,inputMonitoring:true,shortcutEnabled:true,shortcutActive:true)
        precondition(denied.row(.microphone).button == "打开麦克风设置" && !denied.canContinue)
        let restricted = VoicePermissions(microphone:.restricted,accessibility:true,inputMonitoring:true,shortcutEnabled:true,shortcutActive:true)
        precondition(!restricted.row(.microphone).enabled && !restricted.canInsert)
        // A working event tap is the source of truth; a preflight result alone
        // never marks a connected shortcut as unavailable.
        let tapOnly = VoicePermissions(microphone:.authorized,accessibility:true,inputMonitoring:false,shortcutEnabled:true,shortcutActive:true)
        precondition(tapOnly.shortcutReady && tapOnly.canContinue && tapOnly.row(.inputMonitoring).ready)
        let micOnly = VoicePermissions(microphone:.authorized,accessibility:false,inputMonitoring:false,shortcutEnabled:true,shortcutActive:false)
        precondition(micOnly.microphoneAllowed && !micOnly.canInsert && !micOnly.canContinue)
        // Accessibility is present but the tap could not start and Input
        // Monitoring preflight is false: this is the stale-signature case.
        let stale = VoicePermissions(microphone:.authorized,accessibility:true,inputMonitoring:false,shortcutEnabled:true,shortcutActive:false,shortcutFailure:"输入监控授权可能已失效")
        precondition(!stale.shortcutReady && stale.needsGuidance)
        precondition(stale.row(.inputMonitoring).status.contains("移除后重新添加"))
        let disabled = VoicePermissions(microphone:.authorized,accessibility:true,inputMonitoring:true,shortcutEnabled:false,shortcutActive:false)
        precondition(disabled.canContinue && disabled.row(.inputMonitoring).button == "启用快捷键")
        let reconnect = VoicePermissions(microphone:.authorized,accessibility:true,inputMonitoring:true,shortcutEnabled:true,shortcutActive:false)
        precondition(reconnect.row(.inputMonitoring).button == "重新连接快捷键" && reconnect.needsGuidance)
        let ready = VoicePermissions(microphone:.authorized,accessibility:true,inputMonitoring:true,shortcutEnabled:true,shortcutActive:true)
        precondition(ready.canContinue && !ready.needsGuidance && VoicePermission.allCases.allSatisfy { ready.row($0).ready })
        print("Permissions passed: first request, denial, restriction, tap-only, microphone-only, stale signature, disabled shortcut, reconnect, ready")
    }
}
