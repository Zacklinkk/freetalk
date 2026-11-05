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
        let micOnly = VoicePermissions(microphone:.authorized,accessibility:false,inputMonitoring:false,shortcutEnabled:true,shortcutActive:false)
        precondition(micOnly.microphoneAllowed && !micOnly.canInsert && !micOnly.canContinue)
        let revoked = VoicePermissions(microphone:.authorized,accessibility:true,inputMonitoring:false,shortcutEnabled:true,shortcutActive:true)
        precondition(!revoked.shortcutReady && revoked.needsGuidance)
        let disabled = VoicePermissions(microphone:.authorized,accessibility:true,inputMonitoring:true,shortcutEnabled:false,shortcutActive:false)
        precondition(disabled.canContinue && disabled.row(.inputMonitoring).button == "启用右 Option")
        let reconnect = VoicePermissions(microphone:.authorized,accessibility:true,inputMonitoring:true,shortcutEnabled:true,shortcutActive:false)
        precondition(reconnect.row(.inputMonitoring).button == "重新连接快捷键" && reconnect.needsGuidance)
        let ready = VoicePermissions(microphone:.authorized,accessibility:true,inputMonitoring:true,shortcutEnabled:true,shortcutActive:true)
        precondition(ready.canContinue && !ready.needsGuidance && VoicePermission.allCases.allSatisfy { ready.row($0).ready })
        print("Permissions passed: first request, denial, restriction, microphone-only mode, revoked monitoring, disabled shortcut, reconnect, ready")
    }
}
