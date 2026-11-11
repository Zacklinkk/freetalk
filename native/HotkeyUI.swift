import AppKit
import Carbon

/// Records one shortcut using local key events. Local monitors only receive
/// events while the app is active, so recording itself needs no extra
/// permission; the saved binding is later served by the global event tap.
final class HotkeyRecorder {
    enum Result {
        case recorded(HotkeyBinding)
        case cancelled
    }
    private var monitor: Any?
    private var held: Set<HotkeyModifier> = []
    private var modifierDownAt: TimeInterval?
    private var chordSeen = false
    // Keeps a rejection message visible until the rejected keys are released.
    private var rejected = false
    private var validator: ((HotkeyBinding) -> String?)?
    private var onStatus: ((String) -> Void)?
    private var onFinish: ((Result) -> Void)?

    var isRecording: Bool { monitor != nil }

    func begin(validate: @escaping (HotkeyBinding) -> String?,
               onStatus: @escaping (String) -> Void,
               onFinish: @escaping (Result) -> Void) {
        cancel()
        self.validator = validate
        self.onStatus = onStatus
        self.onFinish = onFinish
        held = []; modifierDownAt = nil; chordSeen = false; rejected = false
        onStatus("请按下新的快捷键：轻按单个修饰键，或按住修饰键再按其他键。Esc 取消。")
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            guard let self, self.isRecording else { return event }
            self.handle(event)
            return nil
        }
    }

    func cancel() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        validator = nil; onStatus = nil; onFinish = nil
        held = []; modifierDownAt = nil; chordSeen = false; rejected = false
    }

    private func finish(_ result: Result) {
        let callback = onFinish
        cancel()
        callback?(result)
    }

    private func handle(_ event: NSEvent) {
        let now = ProcessInfo.processInfo.systemUptime
        if event.type == .flagsChanged {
            guard let modifier = HotkeyModifier(rawValue: Int(event.keyCode)) else { return }
            let down = isDown(modifier, event: event)
            if down {
                if held.isEmpty { modifierDownAt = now; chordSeen = false; rejected = false }
                held.insert(modifier)
                if held.count > 1 { chordSeen = true }
                if !rejected { onStatus?("已按下 \(modifier.display)；松开确认，或继续按其他键录制组合键。") }
            } else {
                held.remove(modifier)
                let duration = modifierDownAt.map { now - $0 } ?? 1
                if held.isEmpty {
                    defer { modifierDownAt = nil; chordSeen = false; rejected = false }
                    if rejected { return }
                    if !chordSeen && duration <= 0.45 {
                        record(HotkeyBinding(trigger: .modifierTap(modifier)))
                        return
                    }
                    if !chordSeen {
                        onStatus?("按住超过 0.45 秒，已取消；请轻按修饰键或使用组合键。")
                    } else {
                        onStatus?("请只轻按一个修饰键，或按住修饰键再按其他键。")
                    }
                }
            }
            return
        }
        guard event.type == .keyDown, !event.isARepeat else { return }
        let code = Int(event.keyCode)
        if code == 53 && held.isEmpty { finish(.cancelled); return }
        if held.isEmpty {
            if HotkeyKeyName.isFunctionKey(code) {
                record(HotkeyBinding(trigger: .chord(keyCode: code, modifiers: [])))
            } else {
                onStatus?("请先按住 Command/Control/Option/Fn，或选择 F1–F20。")
            }
            return
        }
        record(HotkeyBinding(trigger: .chord(keyCode: code, modifiers: HotkeyModifier.ordered(held))))
    }

    private func record(_ binding: HotkeyBinding) {
        if let problem = validator?(binding) {
            onStatus?("不能使用：\(problem)")
            // Keep tracking the keys that are still down so their release does
            // not replace this message or record a modifier tap by accident.
            rejected = !held.isEmpty; chordSeen = true
            return
        }
        finish(.recorded(binding))
    }

    private func isDown(_ modifier: HotkeyModifier, event: NSEvent) -> Bool {
        if modifier == .function {
            return event.cgEvent?.flags.contains(.maskSecondaryFn) ?? false
        }
        if let flags = event.cgEvent?.flags, flags.rawValue != 0 {
            return modifier.isDown(in: flags)
        }
        return CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(modifier.rawValue))
    }
}

/// Listens for the configured shortcut while the global tap is live and reports
/// whether the key actually arrives. It never starts a recording.
final class HotkeyTestController {
    private weak var hotkey: GlobalHotkey?
    private var timer: Timer?
    private var binding: HotkeyBinding?
    private var onStatus: ((String) -> Void)?
    private var lastReceived: String?
    var isRunning: Bool { timer != nil }

    func start(binding: HotkeyBinding, hotkey: GlobalHotkey, seconds: TimeInterval = 8,
               onStatus: @escaping (String) -> Void) {
        stop()
        self.hotkey = hotkey
        self.binding = binding
        self.onStatus = onStatus
        guard hotkey.active else {
            if let failure = hotkey.failure { onStatus("监听未启动：\(failure)。请先处理下方的系统权限。") }
            else { onStatus("监听未启动：请先勾选「启用全局快捷键」。") }
            return
        }
        hotkey.testing = true
        hotkey.onTestEvent = { [weak self] event in self?.handle(event) }
        onStatus("测试中：请在任意应用中按下 \(binding.display)（\(Int(seconds)) 秒）")
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self, let binding = self.binding else { return }
            if let last = self.lastReceived {
                self.finish("测试结束：监听正常，但没有匹配到 \(binding.display)。最后收到「\(last)」，请检查左右键或组合是否一致。")
            } else if IsSecureEventInputEnabled() {
                // Secure Event Input (password fields, Terminal's “Secure
                // Keyboard Entry”) hides keystrokes from every event tap.
                self.finish("未收到按键：系统正处于安全输入状态（密码框或终端的“安全键盘输入”），全局快捷键暂时收不到按键。")
            } else {
                self.finish("未收到任何按键：监听已连接，但 \(Int(seconds)) 秒内没有按键送达。若确实按过，可能被其他应用拦截。")
            }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        hotkey?.testing = false
        hotkey?.onTestEvent = nil
        hotkey = nil; binding = nil; onStatus = nil; lastReceived = nil
    }

    private func handle(_ event: HotkeyTestEvent) {
        guard let binding else { return }
        lastReceived = event.description
        if event.matched {
            let elapsed = event.elapsed.map { String(format: "（%.2f 秒）", $0) } ?? ""
            NSSound(named: "Glass")?.play()
            finish("✓ 已收到：\(event.description)\(elapsed)")
            return
        }
        if let hint = event.hint {
            onStatus?("收到 \(event.description)，但\(hint)，不算一次轻按。请轻按后立即松开。")
            return
        }
        if binding.isModifierTap && event.description == binding.display {
            onStatus?("已按下 \(event.description)，松开后完成测试…")
            return
        }
        onStatus?("监听正常：收到「\(event.description)」，但未匹配 \(binding.display)。")
    }

    private func finish(_ message: String) {
        let callback = onStatus
        stop()
        callback?(message)
    }
}
