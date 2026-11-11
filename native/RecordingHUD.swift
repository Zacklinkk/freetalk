import AppKit
import QuartzCore

final class VoiceHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
final class VoiceHUDButton: NSButton {
    override var needsPanelToBecomeKey: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
final class VoiceSpectrum: NSView {
    static let mint = NSColor.systemMint
    static let warningRed = NSColor.systemRed
    var level: Float = 0 { didSet { needsDisplay = true } }
    var active = false { didSet { needsDisplay = true } }
    private(set) var warning = false
    private var transitionStart: TimeInterval?
    private var transitionDuration: TimeInterval = 0.8
    private var rotates = false
    private var animationTimer: Timer?

    func setWarning(_ value: Bool, animated: Bool = true) {
        guard warning != value else { return }
        animationTimer?.invalidate(); animationTimer = nil
        warning = value; transitionStart = nil; rotates = false
        if value && animated {
            rotates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            transitionDuration = rotates ? 0.8 : 0.2
            transitionStart = CACurrentMediaTime()
            let timer = Timer(timeInterval: 1.0/60, repeats: true) { [weak self] timer in
                guard let self = self, let start = self.transitionStart else { timer.invalidate(); return }
                self.needsDisplay = true
                if CACurrentMediaTime() - start >= self.transitionDuration {
                    timer.invalidate(); self.animationTimer = nil; self.transitionStart = nil
                }
            }
            animationTimer = timer; RunLoop.main.add(timer, forMode: .common)
        }
        needsDisplay = true
    }
    deinit { animationTimer?.invalidate() }
    override func draw(_ dirtyRect: NSRect) {
        let heights:[CGFloat] = [0.25,0.5,0.78,1,0.7,0.46,0.22]
        let amplitude=active ? min(1,max(0,CGFloat(level)*13)) : 0
        let progress = transitionStart.map { min(1, max(0, (CACurrentMediaTime() - $0) / transitionDuration)) } ?? 1
        let ease = progress * progress * (3 - 2 * progress)
        let tint=active ? Self.mint.blended(withFraction:warning ? ease : 0,of:Self.warningRed)! : .tertiaryLabelColor
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        if warning && rotates && transitionStart != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let transform = NSAffineTransform()
            transform.translateX(by: bounds.midX, yBy: bounds.midY)
            transform.rotate(byDegrees: CGFloat(360 * ease))
            transform.translateX(by: -bounds.midX, yBy: -bounds.midY); transform.concat()
        }
        tint.setFill()
        for (i,shape) in heights.enumerated() {
            let height=3+22*shape*amplitude
            NSBezierPath(roundedRect:NSRect(x:(bounds.width-33)/2+CGFloat(i)*5,y:(bounds.height-height)/2,width:3,height:height),xRadius:1.5,yRadius:1.5).fill()
        }
    }
}
final class RecordingHUD: NSObject {
    private enum ActionMode { case stop, copy, undo }
    private let panel: NSPanel
    private let title=NSTextField(labelWithString:""), destination=NSTextField(labelWithString:"")
    private let spectrum=VoiceSpectrum(), icon=NSImageView(), clock=NSTextField(labelWithString:"")
    private let action=VoiceHUDButton(), cancel=VoiceHUDButton()
    private var anchor:CGRect?, originalDestination=""
    private var hasTarget=false, finished=false
    private var actionMode=ActionMode.stop
    private var hideTimer:Timer?
    var onStop:(()->Void)?, onCancel:(()->Void)?, onCopy:(()->Void)?, onUndo:(()->Void)?, onDismiss:(()->Void)?
    init(panel suppliedPanel: NSPanel? = nil) {
        panel=suppliedPanel ?? VoiceHUDPanel(contentRect:NSRect(x:0,y:0,width:340,height:68),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        super.init()
        panel.title="freetalk · 录音位置提示"; panel.isFloatingPanel=true; panel.level = .floating
        panel.hidesOnDeactivate=false; panel.becomesKeyOnlyIfNeeded=true; panel.isReleasedWhenClosed=false
        panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]; panel.isOpaque=false; panel.backgroundColor = .clear; panel.hasShadow=false
        let surface=NSVisualEffectView(); surface.material = .hudWindow; surface.state = .active; surface.blendingMode = .behindWindow; surface.wantsLayer=true; surface.layer?.cornerRadius=24; surface.layer?.masksToBounds=true
        surface.layer?.backgroundColor=NSColor.windowBackgroundColor.withAlphaComponent(0.2).cgColor
        surface.layer?.borderWidth=0.5; surface.layer?.borderColor=NSColor.separatorColor.cgColor
        panel.contentView=surface
        title.font = .systemFont(ofSize:13,weight:.semibold); title.textColor = .labelColor; title.lineBreakMode = .byTruncatingTail
        destination.font = .systemFont(ofSize:10.5); destination.textColor = .secondaryLabelColor; destination.lineBreakMode = .byTruncatingMiddle
        clock.font = .monospacedDigitSystemFont(ofSize:11,weight:.medium); clock.textColor = .secondaryLabelColor
        spectrum.setAccessibilityLabel("录音音量阶梯")
        spectrum.setAccessibilityElement(true); spectrum.setAccessibilityRole(.image)
        icon.contentTintColor=NSColor.systemMint
        action.target=self; action.action = #selector(primary); action.isBordered=false; action.font = .systemFont(ofSize:11,weight:.medium); action.contentTintColor = .labelColor
        cancel.title=""; cancel.image=NSImage(systemSymbolName:"xmark",accessibilityDescription:nil); cancel.target=self; cancel.action = #selector(closeAction); cancel.isBordered=false; cancel.contentTintColor = .secondaryLabelColor
        cancel.setAccessibilityLabel("取消录音或关闭提示")
        for view in [spectrum,icon,title,destination,clock,action,cancel] as [NSView] { surface.addSubview(view); view.translatesAutoresizingMaskIntoConstraints=false }
        NSLayoutConstraint.activate([
            spectrum.leadingAnchor.constraint(equalTo:surface.leadingAnchor,constant:14),spectrum.centerYAnchor.constraint(equalTo:surface.centerYAnchor),spectrum.widthAnchor.constraint(equalToConstant:44),spectrum.heightAnchor.constraint(equalToConstant:44),
            icon.centerXAnchor.constraint(equalTo:spectrum.centerXAnchor),icon.centerYAnchor.constraint(equalTo:spectrum.centerYAnchor),icon.widthAnchor.constraint(equalToConstant:23),icon.heightAnchor.constraint(equalToConstant:23),
            title.leadingAnchor.constraint(equalTo:spectrum.trailingAnchor,constant:8),title.topAnchor.constraint(equalTo:surface.topAnchor,constant:15),title.trailingAnchor.constraint(lessThanOrEqualTo:clock.leadingAnchor,constant:-6),
            clock.trailingAnchor.constraint(equalTo:action.leadingAnchor,constant:-7),clock.centerYAnchor.constraint(equalTo:title.centerYAnchor),clock.widthAnchor.constraint(equalToConstant:36),
            destination.leadingAnchor.constraint(equalTo:title.leadingAnchor),destination.trailingAnchor.constraint(equalTo:cancel.trailingAnchor),destination.topAnchor.constraint(equalTo:title.bottomAnchor,constant:5),
            cancel.trailingAnchor.constraint(equalTo:surface.trailingAnchor,constant:-15),cancel.centerYAnchor.constraint(equalTo:title.centerYAnchor),cancel.widthAnchor.constraint(equalToConstant:16),cancel.heightAnchor.constraint(equalToConstant:20),
            action.trailingAnchor.constraint(equalTo:cancel.leadingAnchor,constant:-10),action.centerYAnchor.constraint(equalTo:title.centerYAnchor),action.widthAnchor.constraint(equalToConstant:32),action.heightAnchor.constraint(equalToConstant:28)
        ])
    }
    func show(target:InputSnapshot?) {
        hideTimer?.invalidate(); finished=false; actionMode = .stop; anchor=target?.anchor; hasTarget=target != nil
        position(anchor)
        if let target=target {
            let line=(target.value as NSString).substring(to:target.range.location).components(separatedBy:"\n").count
            originalDestination="\(target.name) · 第\(line)行 · \(target.range.length > 0 ? "替换选区" : "光标处输入")"
        } else { originalDestination="未锁定输入框 · 结果可复制" }
        destination.stringValue=originalDestination; destination.toolTip=originalDestination
        title.stringValue="准备录音"; title.toolTip=nil; clock.stringValue=""; icon.isHidden=true; spectrum.isHidden=false; spectrum.active=false; spectrum.level=0
        resetWarning()
        action.title=""; action.image=NSImage(systemSymbolName:"stop.circle.fill",accessibilityDescription:"停止录音")?.withSymbolConfiguration(.init(pointSize:20,weight:.regular)); action.setAccessibilityLabel("停止录音"); action.isEnabled=false
        panel.orderFrontRegardless()
    }
    func showMeeting(shortcut: String) {
        show(target:nil)
        originalDestination = "保存到会议资料 · \(shortcut) 结束"
        destination.stringValue = originalDestination; title.stringValue = "准备会议录音"
        action.isEnabled = true
    }
    func updateMeeting(level:Float,seconds:Double) {
        guard panel.isVisible,!finished else { return }
        title.stringValue = "会议录音"; destination.stringValue = originalDestination
        clock.stringValue = String(format:"%02d:%02d",Int(seconds)/60,Int(seconds)%60)
        spectrum.active = true; spectrum.level = level
    }
    func finishMeeting(_ message:String) {
        finished = true; spectrum.active = false; title.stringValue = "会议录音已停止"
        destination.stringValue = message; clock.stringValue = ""; action.isEnabled = false
        scheduleHide()
    }
    func update(recording:Bool,timing:DictationTiming,level:Float,stage:String,targetIssue:String?,anchor:CGRect?) {
        guard panel.isVisible,!finished else { return }
        if let anchor=anchor { self.anchor=anchor; position(anchor) }
        let countdown = recording ? timing.countdown : nil
        title.stringValue=recording ? (countdown == nil ? "正在聆听" : "即将自动结束") : stage.contains("麦克风") ? "准备录音" : stage.contains("整理") ? "整理表达" : stage.contains("输入") ? "正在输入" : "正在转写"
        title.toolTip=recording ? "达到本次上限 \(DictationLimit.title(timing.limit)) 后自动停止并整理。" : stage
        clock.stringValue=recording ? (countdown.map { "\($0)s" } ?? String(format:"%02d:%02d",Int(timing.elapsed)/60,Int(timing.elapsed)%60)) : ""
        clock.setAccessibilityLabel(countdown == nil ? "录音时长" : "自动结束倒计时")
        clock.textColor=countdown == nil ? .secondaryLabelColor : VoiceSpectrum.warningRed
        spectrum.setWarning(countdown != nil)
        destination.stringValue=hasTarget && targetIssue != nil ? "位置已变化 · 暂不输入" : originalDestination
        destination.toolTip=targetIssue ?? originalDestination
        spectrum.active=recording; spectrum.level=level
        action.isEnabled=recording
    }
    func finish(success:Bool,message:String) {
        hideTimer?.invalidate(); finished=true; actionMode = .copy
        resetWarning()
        title.stringValue=success ? "已输入" : "结果已保留"; clock.stringValue=""
        spectrum.isHidden=true; icon.isHidden=false; icon.image=NSImage(systemSymbolName:success ? "checkmark.circle.fill" : "doc.on.clipboard",accessibilityDescription:nil)
        destination.stringValue=message; destination.toolTip=message
        action.title=""; action.image=NSImage(systemSymbolName:"doc.on.doc",accessibilityDescription:"复制结果"); action.setAccessibilityLabel("复制结果"); action.isEnabled=true
        scheduleHide()
    }
    func showLearning(title text:String,detail:String,anchor:CGRect?) {
        hideTimer?.invalidate(); finished=true; actionMode = .undo; self.anchor=anchor; position(anchor)
        resetWarning()
        title.stringValue=text; title.toolTip=text; destination.stringValue=detail; destination.toolTip=detail; clock.stringValue=""
        spectrum.isHidden=true; icon.isHidden=false; icon.image=NSImage(systemSymbolName:"sparkles",accessibilityDescription:"已学习")
        action.title="撤销"; action.image=nil; action.setAccessibilityLabel("撤销刚学到的纠正"); action.isEnabled=true
        panel.orderFrontRegardless(); scheduleHide()
    }
    private func scheduleHide() { hideTimer=Timer.scheduledTimer(withTimeInterval:5,repeats:false) { [weak self] _ in self?.hide() } }
    private func resetWarning() {
        spectrum.setWarning(false, animated:false); clock.textColor = .secondaryLabelColor
    }
    func hide() { hideTimer?.invalidate(); resetWarning(); panel.orderOut(nil); onDismiss?() }
    private func position(_ ax:CGRect?) {
        let frame:CGRect
        if let ax=ax { let top=NSScreen.screens.first?.frame.maxY ?? 0; frame=CGRect(x:ax.minX,y:top-ax.maxY,width:max(1,ax.width),height:ax.height) }
        else { frame=CGRect(origin:NSEvent.mouseLocation,size:.zero) }
        let screen=NSScreen.screens.first(where: { $0.frame.intersects(frame.insetBy(dx:-1,dy:-1)) }) ?? NSScreen.main
        guard let visible=screen?.visibleFrame else { return }
        let width=panel.frame.width,height=panel.frame.height
        var y=frame.minY-height-10
        if y<visible.minY+8 { y=frame.maxY+10 }
        let x=min(max(frame.minX,visible.minX+8),visible.maxX-width-8)
        y=min(max(y,visible.minY+8),visible.maxY-height-8)
        panel.setFrameOrigin(NSPoint(x:x,y:y))
    }
    @objc private func primary() {
        switch actionMode { case .stop:onStop?(); case .copy:onCopy?();hide(); case .undo:onUndo?();hide() }
    }
    @objc private func closeAction() { if finished { hide() } else { onCancel?() } }
}
