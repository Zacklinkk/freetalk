import AppKit

final class VoiceHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
final class VoiceHUDButton: NSButton {
    override var needsPanelToBecomeKey: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
final class VoiceSpectrum: NSView {
    var level: Float = 0 { didSet { needsDisplay = true } }
    var active = false { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let heights:[CGFloat] = [0.25,0.5,0.78,1,0.7,0.46,0.22]
        let amplitude=active ? min(1,max(0,CGFloat(level)*13)) : 0
        let tint=active ? NSColor(calibratedRed:0.53,green:0.91,blue:0.82,alpha:1) : .white.withAlphaComponent(0.45)
        tint.setFill()
        for (i,shape) in heights.enumerated() {
            let height=3+(bounds.height-3)*shape*amplitude
            NSBezierPath(roundedRect:NSRect(x:CGFloat(i)*5,y:(bounds.height-height)/2,width:3,height:height),xRadius:1.5,yRadius:1.5).fill()
        }
    }
}
final class RecordingHUD: NSObject {
    private enum ActionMode { case stop, copy, undo }
    private let panel: VoiceHUDPanel
    private let title=NSTextField(labelWithString:""), destination=NSTextField(labelWithString:"")
    private let spectrum=VoiceSpectrum(), icon=NSImageView(), clock=NSTextField(labelWithString:"")
    private let action=VoiceHUDButton(), cancel=VoiceHUDButton()
    private var anchor:CGRect?, originalDestination=""
    private var hasTarget=false, finished=false
    private var actionMode=ActionMode.stop
    private var hideTimer:Timer?
    var onStop:(()->Void)?, onCancel:(()->Void)?, onCopy:(()->Void)?, onUndo:(()->Void)?, onDismiss:(()->Void)?
    override init() {
        panel=VoiceHUDPanel(contentRect:NSRect(x:0,y:0,width:340,height:68),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        super.init()
        panel.title="freetalk · 录音位置提示"; panel.isFloatingPanel=true; panel.level = .floating
        panel.hidesOnDeactivate=false; panel.becomesKeyOnlyIfNeeded=true; panel.isReleasedWhenClosed=false
        panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]; panel.isOpaque=false; panel.backgroundColor = .clear; panel.hasShadow=true
        let surface=NSView(); surface.wantsLayer=true; surface.layer?.cornerRadius=34; surface.layer?.masksToBounds=true
        surface.layer?.backgroundColor=NSColor(calibratedWhite:0.09,alpha:0.97).cgColor
        surface.layer?.borderWidth=0.5; surface.layer?.borderColor=NSColor.white.withAlphaComponent(0.16).cgColor
        panel.contentView=surface
        title.font = .systemFont(ofSize:13,weight:.semibold); title.textColor = .white; title.lineBreakMode = .byTruncatingTail
        destination.font = .systemFont(ofSize:10.5); destination.textColor = .white.withAlphaComponent(0.65); destination.lineBreakMode = .byTruncatingMiddle
        clock.font = .monospacedDigitSystemFont(ofSize:11,weight:.medium); clock.textColor = .white.withAlphaComponent(0.7)
        spectrum.setAccessibilityLabel("录音音量阶梯")
        spectrum.setAccessibilityElement(true); spectrum.setAccessibilityRole(.image)
        icon.contentTintColor=NSColor(calibratedRed:0.53,green:0.91,blue:0.82,alpha:1)
        action.target=self; action.action = #selector(primary); action.isBordered=false; action.font = .systemFont(ofSize:11,weight:.medium); action.contentTintColor = .white
        cancel.title=""; cancel.image=NSImage(systemSymbolName:"xmark",accessibilityDescription:nil); cancel.target=self; cancel.action = #selector(closeAction); cancel.isBordered=false; cancel.contentTintColor = .white.withAlphaComponent(0.55)
        cancel.setAccessibilityLabel("取消录音或关闭提示")
        for view in [spectrum,icon,title,destination,clock,action,cancel] as [NSView] { surface.addSubview(view); view.translatesAutoresizingMaskIntoConstraints=false }
        NSLayoutConstraint.activate([
            spectrum.leadingAnchor.constraint(equalTo:surface.leadingAnchor,constant:20),spectrum.centerYAnchor.constraint(equalTo:surface.centerYAnchor),spectrum.widthAnchor.constraint(equalToConstant:33),spectrum.heightAnchor.constraint(equalToConstant:25),
            icon.centerXAnchor.constraint(equalTo:spectrum.centerXAnchor),icon.centerYAnchor.constraint(equalTo:spectrum.centerYAnchor),icon.widthAnchor.constraint(equalToConstant:23),icon.heightAnchor.constraint(equalToConstant:23),
            title.leadingAnchor.constraint(equalTo:spectrum.trailingAnchor,constant:13),title.topAnchor.constraint(equalTo:surface.topAnchor,constant:15),title.trailingAnchor.constraint(lessThanOrEqualTo:clock.leadingAnchor,constant:-6),
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
        action.title=""; action.image=NSImage(systemSymbolName:"stop.circle.fill",accessibilityDescription:"停止录音")?.withSymbolConfiguration(.init(pointSize:20,weight:.regular)); action.setAccessibilityLabel("停止录音"); action.isEnabled=false
        panel.orderFrontRegardless()
    }
    func update(recording:Bool,seconds:Double,level:Float,stage:String,targetIssue:String?,anchor:CGRect?) {
        guard panel.isVisible,!finished else { return }
        if let anchor=anchor { self.anchor=anchor; position(anchor) }
        title.stringValue=recording ? "正在聆听" : stage.contains("麦克风") ? "准备录音" : stage.contains("整理") ? "整理表达" : stage.contains("输入") ? "正在输入" : "正在转写"
        title.toolTip=stage; clock.stringValue=recording ? String(format:"%02d:%02d",Int(seconds)/60,Int(seconds)%60) : ""
        destination.stringValue=hasTarget && targetIssue != nil ? "位置已变化 · 暂不输入" : originalDestination
        destination.toolTip=targetIssue ?? originalDestination
        spectrum.active=recording; spectrum.level=level
        action.isEnabled=recording
    }
    func finish(success:Bool,message:String) {
        hideTimer?.invalidate(); finished=true; actionMode = .copy
        title.stringValue=success ? "已输入" : "结果已保留"; clock.stringValue=""
        spectrum.isHidden=true; icon.isHidden=false; icon.image=NSImage(systemSymbolName:success ? "checkmark.circle.fill" : "doc.on.clipboard",accessibilityDescription:nil)
        destination.stringValue=message; destination.toolTip=message
        action.title=""; action.image=NSImage(systemSymbolName:"doc.on.doc",accessibilityDescription:"复制结果"); action.setAccessibilityLabel("复制结果"); action.isEnabled=true
        scheduleHide()
    }
    func showLearning(title text:String,detail:String,anchor:CGRect?) {
        hideTimer?.invalidate(); finished=true; actionMode = .undo; self.anchor=anchor; position(anchor)
        title.stringValue=text; title.toolTip=text; destination.stringValue=detail; destination.toolTip=detail; clock.stringValue=""
        spectrum.isHidden=true; icon.isHidden=false; icon.image=NSImage(systemSymbolName:"sparkles",accessibilityDescription:"已学习")
        action.title="撤销"; action.image=nil; action.setAccessibilityLabel("撤销刚学到的纠正"); action.isEnabled=true
        panel.orderFrontRegardless(); scheduleHide()
    }
    private func scheduleHide() { hideTimer=Timer.scheduledTimer(withTimeInterval:5,repeats:false) { [weak self] _ in self?.hide() } }
    func hide() { hideTimer?.invalidate(); panel.orderOut(nil); onDismiss?() }
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
