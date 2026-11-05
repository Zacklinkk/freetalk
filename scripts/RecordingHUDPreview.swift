import AppKit

// Only the preview accepts focus so UI inspection can select the HUD window.
// Production uses VoiceHUDPanel, which never becomes key or main.
final class PreviewHUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Exercises production HUD/settings views without audio, model loading, input
/// permissions, history writes, or changes to the real application's preferences.
final class HUDPreview: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let panel = PreviewHUDPanel(contentRect:NSRect(x:0,y:0,width:340,height:68),styleMask:[.borderless],backing:.buffered,defer:false)
    lazy var hud = RecordingHUD(panel:panel)
    let suite = "io.github.zacklinkk.freetalk.hud-preview.fixtures"
    var window: NSWindow!
    var timer: Timer?
    var returnTimer: Timer?
    var clock = DictationClock(limit:90)
    var label = NSTextField(labelWithString:"仅演示界面，不启动麦克风、不输入文字。")
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:540,height:300),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.title = "freetalk · 倒计时预览"; window.delegate = self; window.isReleasedWhenClosed = false; window.center()
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:24),stack.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-24),stack.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:24)])
        stack.addArrangedSubview(label)
        let settings = RecordingLimitView(defaults:UserDefaults(suiteName:suite)!,legacy:{90})
        stack.addArrangedSubview(settings); settings.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive = true
        let buttons = NSStackView(); buttons.spacing = 10
        for (title,selector) in [("预览最后 12 秒",#selector(play)),("回到普通录音",#selector(reset)),("关闭浮窗",#selector(hide))] {
            let button = NSButton(title:title,target:self,action:selector); button.bezelStyle = .rounded; buttons.addArrangedSubview(button)
        }
        stack.addArrangedSubview(buttons)
        hud.onStop = { [weak self] in self?.finish() }; hud.onCancel = { [weak self] in self?.hide() }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
    }
    var anchor: CGRect {
        let frame = window.frame, top = NSScreen.screens.first!.frame.maxY
        return CGRect(x:frame.minX+70,y:top-frame.minY-30,width:350,height:20)
    }
    @objc func play() {
        timer?.invalidate(); returnTimer?.invalidate(); hud.show(target:nil); clock = DictationClock(limit:90)
        clock.start(at:ProcessInfo.processInfo.systemUptime-78)
        label.stringValue = "播放最后 12 秒：一次轻旋、平滑变红、倒计时后结束。"
        panel.makeKeyAndOrderFront(nil)
        timer = Timer(timeInterval:1.0/30,repeats:true) { [weak self] _ in
            guard let self = self else { return }
            let timing = self.clock.snapshot()
            if timing.expired { self.finish(); return }
            let level = Float(0.035 + 0.035 * abs(sin(timing.elapsed*3)))
            self.hud.update(recording:true,timing:timing,level:level,stage:"界面预览",targetIssue:nil,anchor:self.anchor)
        }
        RunLoop.main.add(timer!,forMode:.common)
    }
    func finish() {
        timer?.invalidate(); label.stringValue = "预览完成，5 秒后隐藏；未录音或输入文字。"
        hud.finish(success:false,message:"预览完成 · 未录音或输入文字")
        returnTimer = Timer.scheduledTimer(withTimeInterval:5.2,repeats:false) { [weak self] _ in self?.window.makeKeyAndOrderFront(nil) }
    }
    @objc func reset() {
        timer?.invalidate(); hud.show(target:nil)
        hud.update(recording:true,timing:DictationTiming(limit:90,elapsed:12),level:0.055,stage:"界面预览",targetIssue:nil,anchor:anchor)
        panel.makeKeyAndOrderFront(nil)
        label.stringValue = "普通录音状态：已恢复薄荷绿，没有倒计时。"
    }
    @objc func hide() { timer?.invalidate(); returnTimer?.invalidate(); hud.hide(); window.makeKeyAndOrderFront(nil) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification:Notification) {
        timer?.invalidate(); hud.hide(); UserDefaults(suiteName:suite)?.removePersistentDomain(forName:suite)
    }
}

@main struct RecordingHUDPreview {
    static func main() {
        let app = NSApplication.shared, delegate = HUDPreview(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
