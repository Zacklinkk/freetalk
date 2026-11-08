import AppKit
import AVFoundation
import ApplicationServices

private let talkAccent = NSColor(name:nil) { appearance in
    appearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua
        ? NSColor(calibratedRed:0.40,green:0.83,blue:0.69,alpha:1)
        : NSColor(calibratedRed:0.12,green:0.40,blue:0.33,alpha:1)
}

final class VoiceMarkView: NSView {
    var level: Float = 0 { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width:136,height:70) }
    override func draw(_ dirtyRect: NSRect) {
        let heights: [CGFloat] = [18,32,52,64,42,26,14]
        for (i,height) in heights.enumerated() {
            let h = min(68,height * (1 + CGFloat(min(level*5,0.6))))
            talkAccent.withAlphaComponent(0.48 + Double(i%3)*0.2).setFill()
            NSBezierPath(roundedRect:NSRect(x:CGFloat(i)*18+5,y:(bounds.height-h)/2,width:10,height:h),xRadius:5,yRadius:5).fill()
        }
    }
}

final class ModelDownloadView: NSStackView {
    unowned let app: AppDelegate
    private let state = NSTextField(wrappingLabelWithString:"")
    private let detail = NSTextField(wrappingLabelWithString:"")
    private let source = NSPopUpButton()
    private let progress = NSProgressIndicator()
    private let start = NSButton(), cancel = NSButton(), log = NSButton()
    private var statuses: [String:NSTextField] = [:]
    private var downloads: [NSButton] = []
    init(app: AppDelegate) {
        self.app = app; super.init(frame:.zero)
        orientation = .vertical; alignment = .leading; spacing = 14
        for item in ModelDownloadSource.allCases { source.addItem(withTitle:item.title) }
        source.target = self; source.action = #selector(changeSource); source.setAccessibilityLabel("模型下载来源")
        addArrangedSubview(app.row([app.label("模型下载源",size:12),source]))
        for model in app.modelSetup.models {
            let status = app.label("",size:12,color:.secondaryLabelColor); statuses[model.key] = status
            let get = NSButton(title:"下载 / 校验",target:self,action:#selector(downloadOne(_:))); get.identifier = NSUserInterfaceItemIdentifier(model.key); get.bezelStyle = .rounded; downloads.append(get)
            let name = model.name.replacingOccurrences(of:"-[0-9]+bit$",with:"",options:.regularExpression)
            let links = ModelDownloadSource.allCases.map { origin -> NSButton in
                let button = NSButton(title:origin == .official ? "官方链接" : "镜像链接",target:self,action:#selector(openSource(_:)))
                button.identifier = NSUserInterfaceItemIdentifier(model.key+":"+origin.rawValue); button.bezelStyle = .inline
                return button
            }
            let box = app.card("\(model.title) · \(name)","\(model.bits)bit · \(ByteCountFormatter.string(fromByteCount:model.bytes,countStyle:.file)) · Apache 2.0",views:[app.row([status,get]+links)])
            addArrangedSubview(box); box.widthAnchor.constraint(equalTo:widthAnchor).isActive = true
        }
        state.font = .systemFont(ofSize:12); state.textColor = .secondaryLabelColor; state.setAccessibilityLabel("模型下载状态")
        detail.font = .monospacedDigitSystemFont(ofSize:11,weight:.regular); detail.textColor = .secondaryLabelColor; detail.setAccessibilityLabel("模型下载进度详情")
        progress.style = .bar; progress.minValue = 0; progress.maxValue = 1
        addArrangedSubview(state); addArrangedSubview(progress); progress.widthAnchor.constraint(equalTo:widthAnchor).isActive = true
        addArrangedSubview(detail); detail.widthAnchor.constraint(equalTo:widthAnchor).isActive = true
        start.title = "下载推荐模型与运行环境"; start.target = self; start.action = #selector(downloadAll); start.bezelStyle = .rounded; start.contentTintColor = talkAccent
        cancel.title = "取消下载"; cancel.target = self; cancel.action = #selector(cancelDownload); cancel.bezelStyle = .rounded
        log.title = "查看下载日志"; log.target = self; log.action = #selector(showLog); log.bezelStyle = .inline
        addArrangedSubview(app.row([start,cancel,log]))
        addArrangedSubview(app.label("模型约3.29 GB，建议预留8 GB空间。镜像下载使用相同版本与 SHA-256 校验。\n来源切换只影响模型；首次准备运行环境仍需访问 GitHub / Astral 与 PyPI。\n不需要账号或 API key；准备好后离线推理。",size:11,color:.secondaryLabelColor))
        refresh()
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    func refresh() {
        let manager = app.modelSetup
        source.selectItem(at:ModelDownloadSource.allCases.firstIndex(of:.preferred) ?? 0); source.isEnabled = !manager.busy
        for model in manager.models { statuses[model.key]?.stringValue = model.filesPresent(config:app.config) ? "文件已就绪 · 可重新校验" : "尚未安装" }
        state.stringValue = !manager.busy && !manager.failed && manager.fraction == 1
            ? (app.worker.ready ? "模型已校验并加载，可以开始使用。" : app.modelText)
            : manager.message
        state.textColor = manager.failed ? .systemRed : .secondaryLabelColor
        detail.stringValue = [manager.progressText,manager.activityText].filter { !$0.isEmpty }.joined(separator:"\n")
        detail.isHidden = detail.stringValue.isEmpty
        log.isEnabled = FileManager.default.fileExists(atPath:manager.support.appendingPathComponent("setup.log").path)
        if let fraction = manager.fraction { progress.isIndeterminate = false; progress.doubleValue = fraction; progress.stopAnimation(nil) }
        else { progress.isIndeterminate = true; if manager.busy { progress.startAnimation(nil) } else { progress.stopAnimation(nil) } }
        progress.isHidden = !manager.busy && manager.fraction == nil
        start.title = manager.failed ? "重试下载" : ModelSetup.configured(app.config) ? "校验已安装模型 / 补齐下载" : "下载推荐模型与运行环境"
        start.isEnabled = !manager.busy && app.phase == .idle && !app.appUpdater.installing
        for button in downloads { button.isEnabled = start.isEnabled }
        cancel.isHidden = !manager.busy; cancel.isEnabled = manager.busy
    }
    @objc private func downloadAll() { app.beginModelDownload() }
    @objc private func downloadOne(_ sender:NSButton) { app.beginModelDownload(only:sender.identifier?.rawValue ?? "all") }
    @objc private func cancelDownload() { app.modelSetup.cancel() }
    @objc private func changeSource() {
        guard !app.modelSetup.busy, ModelDownloadSource.allCases.indices.contains(source.indexOfSelectedItem) else { return }
        UserDefaults.standard.set(ModelDownloadSource.allCases[source.indexOfSelectedItem].rawValue,forKey:"modelDownloadSourceV1")
        app.refreshUI()
    }
    @objc private func openSource(_ sender:NSButton) {
        let parts = sender.identifier?.rawValue.split(separator:":").map(String.init) ?? []
        guard parts.count == 2, let origin = ModelDownloadSource(rawValue:parts[1]),
              let model = app.modelSetup.models.first(where: { $0.key == parts[0] }), let url = model.pageURL(source:origin) else { return }
        NSWorkspace.shared.open(url)
    }
    @objc private func showLog() { NSWorkspace.shared.open(app.modelSetup.support.appendingPathComponent("setup.log")) }
}

/// A guided, optional practice session. It never targets another app or writes history.
final class OnboardingController: NSObject, NSWindowDelegate {
    unowned let app: AppDelegate
    let window: NSWindow
    private(set) var step = 0
    private let content = NSStackView(), stepList = NSStackView()
    private let next = NSButton(), back = NSButton(), later = NSButton()
    private let progressText = NSTextField(labelWithString:"")
    private var stepLabels: [NSTextField] = []
    private var download: ModelDownloadView?
    private var permissionLabels: [NSTextField] = []
    private var permissionButtons: [NSButton] = []
    private var trialButton: NSButton?
    private var trialStatus: NSTextField?
    private var trialPicker: NSPopUpButton?
    private var trialRaw: NSTextView?, trialResult: NSTextView?
    private var mark: VoiceMarkView?
    private var finalStatus: NSTextField?
    private var raw = "", result = "", resultDetail = ""
    private struct TrialResult {
        let number: Int, raw: String, text: String, detail: String
    }
    // Practice stays in memory. Keep enough attempts to compare without changing
    // the promise that onboarding never writes the normal transcription history.
    private var trials: [TrialResult] = []
    private var trialNumber = 0
    private var selectedTrial: Int?
    var wantsTrial: Bool { window.isVisible && window.isKeyWindow && step == 3 }
    init(app: AppDelegate) {
        self.app = app
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:980,height:760),styleMask:[.titled,.closable,.miniaturizable,.fullSizeContentView],backing:.buffered,defer:false)
        super.init()
        window.title = "欢迎使用 freetalk"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false; window.delegate = self; window.center()
        step = min(4,max(0,UserDefaults.standard.integer(forKey:"onboardingStepV2")))
        let root = window.contentView!, sidebar = NSView()
        sidebar.wantsLayer = true; sidebar.layer?.backgroundColor = talkAccent.withAlphaComponent(0.09).cgColor
        sidebar.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(sidebar)
        let brand = app.label("freetalk",size:26); brand.font = .systemFont(ofSize:26,weight:.semibold)
        let subtitle = app.label("说得自然，写得清楚。",size:12,color:.secondaryLabelColor)
        stepList.orientation = .vertical; stepList.alignment = .leading; stepList.spacing = 18
        stepList.addArrangedSubview(brand); stepList.addArrangedSubview(subtitle); stepList.setCustomSpacing(48,after:subtitle)
        for (i,title) in ["认识 freetalk","开启系统权限","准备本地模型","试说一句","准备完成"].enumerated() {
            let text = app.label("\(i+1)  \(title)",size:13); stepLabels.append(text); stepList.addArrangedSubview(text)
        }
        stepList.translatesAutoresizingMaskIntoConstraints = false; sidebar.addSubview(stepList)
        let privacy = app.label("不需要账号\n声音留在这台 Mac",size:12,color:.secondaryLabelColor)
        privacy.translatesAutoresizingMaskIntoConstraints = false; sidebar.addSubview(privacy)
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 18; content.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(content)
        next.title = "开始设置"; next.target = self; next.action = #selector(goNext); next.bezelStyle = .rounded; next.controlSize = .large; next.contentTintColor = talkAccent
        back.title = "上一步"; back.target = self; back.action = #selector(goBack); back.bezelStyle = .rounded
        later.title = "稍后继续"; later.target = self; later.action = #selector(pause); later.bezelStyle = .inline
        let footer = app.row([back,later,NSView(),next]); footer.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(footer)
        progressText.textColor = .tertiaryLabelColor; progressText.font = .monospacedDigitSystemFont(ofSize:11,weight:.medium)
        progressText.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(progressText)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo:root.leadingAnchor),sidebar.topAnchor.constraint(equalTo:root.topAnchor),sidebar.bottomAnchor.constraint(equalTo:root.bottomAnchor),sidebar.widthAnchor.constraint(equalToConstant:235),
            stepList.leadingAnchor.constraint(equalTo:sidebar.leadingAnchor,constant:28),stepList.topAnchor.constraint(equalTo:sidebar.topAnchor,constant:70),stepList.trailingAnchor.constraint(equalTo:sidebar.trailingAnchor,constant:-20),
            privacy.leadingAnchor.constraint(equalTo:stepList.leadingAnchor),privacy.bottomAnchor.constraint(equalTo:sidebar.bottomAnchor,constant:-35),
            content.leadingAnchor.constraint(equalTo:sidebar.trailingAnchor,constant:42),content.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-42),content.topAnchor.constraint(equalTo:root.topAnchor,constant:66),content.bottomAnchor.constraint(lessThanOrEqualTo:footer.topAnchor,constant:-20),
            footer.leadingAnchor.constraint(equalTo:content.leadingAnchor),footer.trailingAnchor.constraint(equalTo:content.trailingAnchor),footer.bottomAnchor.constraint(equalTo:root.bottomAnchor,constant:-30),
            progressText.leadingAnchor.constraint(equalTo:content.leadingAnchor),progressText.bottomAnchor.constraint(equalTo:footer.topAnchor,constant:-14)
        ])
        render()
    }
    func show() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true); refresh() }
    func showPermissions() {
        guard app.phase == .idle else { return }
        step = 1; render(); show()
    }
    private func heading(_ title:String,_ description:String) {
        let text = app.label(title,size:32); text.font = .systemFont(ofSize:32,weight:.semibold); content.addArrangedSubview(text)
        content.addArrangedSubview(app.label(description,size:14,color:.secondaryLabelColor))
    }
    private func add(_ view:NSView) { content.addArrangedSubview(view); view.widthAnchor.constraint(equalTo:content.widthAnchor).isActive = true }
    private func render() {
        UserDefaults.standard.set(step,forKey:"onboardingStepV2")
        for view in content.arrangedSubviews { content.removeArrangedSubview(view); view.removeFromSuperview() }
        download = nil; permissionLabels = []; permissionButtons = []; trialButton = nil; trialStatus = nil; trialPicker = nil; trialRaw = nil; trialResult = nil; mark = nil; finalStatus = nil
        switch step {
        case 0:
            let wave = VoiceMarkView(); content.addArrangedSubview(wave); mark = wave
            heading("想到什么，就说出来。","在输入框放好光标，说话、停下，文字就留在那里。\n语音识别与文字整理，全部在你的 Mac 上完成。")
            add(app.card("效果示例",views:[app.label("说出来",size:11,color:.secondaryLabelColor),app.label("呃，先用十个样本，不对，改成十二个。",size:17),app.label("整理后",size:11,color:talkAccent),app.label("先用12个样本。",size:23)]))
            add(app.label("清理口水词，保留你的意思；遇到明确改口，采用最后的说法。\n不会替你回答问题，也不会自动发送消息。",size:13,color:.secondaryLabelColor))
        case 2:
            heading("先把模型准备好。","只需下载一次。之后无需连接云端语音服务。")
            let view = ModelDownloadView(app:app); download = view; add(view)
        case 1:
            heading("先连接声音和输入框。","按下面的步骤逐项开启，只需在系统设置中允许 freetalk。")
            for permission in VoicePermission.allCases {
                let state = app.label("",size:12,color:.secondaryLabelColor); permissionLabels.append(state)
                let button = NSButton(title:"允许",target:self,action:#selector(grant(_:))); button.tag = permission.rawValue; button.bezelStyle = .rounded; permissionButtons.append(button)
                add(app.card(permission.title,permission.instructions,views:[app.row([state,button])]))
            }
            add(app.row([app.button("我已设置，重新检查",#selector(AppDelegate.recheckPermissions)),app.button("在访达中显示本应用",#selector(AppDelegate.revealApplication))]))
            add(app.label("返回此页会自动检查。若系统要求重开应用，引导会记住这一步。\nTouch ID 或密码由你在系统弹窗操作；只开麦克风也可以先试说。",size:12,color:.secondaryLabelColor))
        case 3:
            heading("试着说一句。","轻按右 Option 开始，再按一次结束；也可以点击按钮。\n最近10次试说仅在本次运行中保留，退出即清除，不输入其他应用。")
            add(app.card("可以照着读",views:[app.label("呃，先用十个样本，不对，改成十二个。保留所有日志。",size:17)]))
            let wave = VoiceMarkView(); wave.heightAnchor.constraint(equalToConstant:45).isActive = true; mark = wave
            let button = NSButton(title:"开始试说",target:self,action:#selector(recordTrial)); button.bezelStyle = .rounded; button.controlSize = .large; trialButton = button
            content.addArrangedSubview(app.row([wave,button]))
            let status = app.label("",size:12,color:.secondaryLabelColor); trialStatus = status; add(status)
            let picker = NSPopUpButton(); picker.target = self; picker.action = #selector(selectTrial(_:)); picker.setAccessibilityLabel("本次试说记录"); trialPicker = picker
            add(app.row([app.label("查看试说",size:11,color:.secondaryLabelColor),picker]))
            reloadTrials()
            trialRaw = textArea(title:"识别原稿",text:raw,height:48)
            trialResult = textArea(title:"整理结果",text:result,height:72)
        default:
            let permissions = VoicePermissions.current(shortcutActive:app.hotkey.active)
            heading(permissions.canInsert ? "下一句话，就用声音。" : "可以先在应用里试说。",permissions.canInsert ? "把光标放进可编辑的输入框，用右 Option 或菜单开始录音。\n结束后先检查草稿，再由你发送。" : "跨应用输入仍需允许辅助功能。\n可从菜单的“权限设置引导”继续授权。")
            let state = app.label("",size:14); finalStatus = state
            add(app.card("你的 freetalk",views:[state]))
            add(app.card("从一开始就好用",views:[app.label("• 常用词：添加名字、项目名称和英文缩写。\n• 自动学习：可靠的短词改字可加入词库，5秒内可撤销。\n• 转写历史：本机保留最近500条，随时复制原稿或结果。",size:14)]))
            add(app.label(result.isEmpty ? "你还没有完成试说，可随时从菜单重新打开引导。" : "这次试说已完成。进入其他应用后，留意光标旁的录音提示。",size:12,color:.secondaryLabelColor))
        }
        refresh()
    }
    private func textArea(title:String,text:String,height:CGFloat) -> NSTextView {
        content.addArrangedSubview(app.label(title,size:11,color:.secondaryLabelColor))
        let textView = NSTextView(); textView.isEditable = false; textView.isSelectable = true; textView.isRichText = false
        textView.font = .systemFont(ofSize:15); textView.textContainerInset = NSSize(width:12,height:10); textView.string = text; textView.setAccessibilityLabel("试说\(title)")
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .noBorder; scroll.documentView = textView
        textView.isVerticallyResizable = true; textView.autoresizingMask = [.width]; textView.textContainer?.widthTracksTextView = true
        scroll.heightAnchor.constraint(equalToConstant:height).isActive = true; add(scroll); return textView
    }
    func refresh() {
        let permissions = VoicePermissions.current(shortcutActive:app.hotkey.active)
        let mic = permissions.microphoneAllowed, ax = permissions.accessibility, keys = permissions.shortcutReady
        for (i,label) in stepLabels.enumerated() { label.textColor = i == step ? talkAccent : .secondaryLabelColor; label.font = .systemFont(ofSize:13,weight:i == step ? .semibold : .regular) }
        let idle = app.phase == .idle
        progressText.stringValue = "\(step+1) / 5"; back.isHidden = step == 0; back.isEnabled = idle
        later.isEnabled = idle; later.title = step == 1 && mic ? "先只用麦克风" : step == 3 ? "跳过试说" : "稍后继续"
        next.title = step == 0 ? "开始设置" : step == 1 ? "继续准备模型" : step == 4 ? (permissions.canInsert ? "开始使用" : "先在应用内使用") : "继续"
        next.isEnabled = idle && !app.modelSetup.busy && (step != 2 || app.worker.ready) && (step != 1 || permissions.canContinue)
        if step == 4 { next.isEnabled = idle && !app.modelSetup.busy && app.worker.ready && mic }
        for permission in VoicePermission.allCases where permission.rawValue < permissionLabels.count {
            let row = permissions.row(permission), i = permission.rawValue
            permissionLabels[i].stringValue = row.status; permissionLabels[i].textColor = row.ready ? talkAccent : .secondaryLabelColor
            permissionButtons[i].title = row.button; permissionButtons[i].isEnabled = row.enabled && idle
        }
        download?.refresh()
        trialButton?.title = app.phase == .recording ? "停止并整理" : app.phase == .preparing ? "取消启动" : app.phase == .processing ? "正在整理…" : result.isEmpty ? "开始试说" : "再试一次"
        trialButton?.isEnabled = app.worker.ready && mic && app.phase != .processing && !app.modelSetup.busy
        trialPicker?.isEnabled = idle && !trials.isEmpty
        mark?.level = app.phase == .recording ? app.level : 0
        trialStatus?.stringValue = app.tutorialSession ? app.statusText : !mic ? "请先允许麦克风访问。" : !app.worker.ready ? app.modelText : resultDetail.isEmpty ? "准备好后点击开始。没有朗读也可以跳过。" : resultDetail
        finalStatus?.stringValue = "本地模型：\(app.worker.ready ? "已就绪" : "等待准备")\n麦克风：\(mic ? "已允许" : "尚未允许")\n跨应用输入：\(ax ? "已允许" : "需在设置中允许")\n右 Option：\(keys ? "可用" : "需在设置中允许")"
    }
    func partial(_ text:String) { trialRaw?.string = text }
    func begin() { raw = ""; result = ""; resultDetail = ""; selectedTrial = nil; reloadTrials(); trialRaw?.string = ""; trialResult?.string = "" }
    func complete(_ response:[String:Any], elapsed:Double) {
        raw = response["raw"] as? String ?? ""; result = response["text"] as? String ?? raw
        let cleanup = response["cleanup"] as? [String:Any] ?? [:]
        resultDetail = result.isEmpty ? "没有识别到文字，请检查麦克风后再试。" : String(format:"停止到文字 %.2f 秒 · %@",elapsed,cleanupSummary(cleanup))
        trialNumber += 1
        trials.append(TrialResult(number:trialNumber,raw:raw,text:result,detail:resultDetail))
        if trials.count > 10 { trials.removeFirst(trials.count-10) }
        selectedTrial = trials.count-1; reloadTrials()
        trialRaw?.string = raw; trialResult?.string = result; refresh()
    }
    private func reloadTrials() {
        guard let picker = trialPicker else { return }
        picker.removeAllItems()
        if selectedTrial == nil { picker.addItem(withTitle:trials.isEmpty ? "完成试说后可回看" : "本次结果尚未完成") }
        for trial in trials.reversed() { picker.addItem(withTitle:"第\(trial.number)次 · \(trial.text.isEmpty ? "未识别到文字" : String(trial.text.prefix(22)))") }
        if let selected = selectedTrial { picker.selectItem(at:trials.count-1-selected) }
    }
    @objc private func selectTrial(_ sender:NSPopUpButton) {
        let offset = selectedTrial == nil ? 1 : 0
        let index = trials.count-1-(sender.indexOfSelectedItem-offset)
        guard app.phase == .idle, trials.indices.contains(index) else { return }
        let trial = trials[index]; selectedTrial = index
        raw = trial.raw; result = trial.text; resultDetail = trial.detail
        reloadTrials(); trialRaw?.string = raw; trialResult?.string = result; refresh()
    }
    @objc private func grant(_ sender:NSButton) { if sender.tag == 0 { app.requestMic() } else if sender.tag == 1 { app.requestAX() } else { app.requestKeys() }; refresh() }
    @objc private func recordTrial() { app.toggle() }
    @objc private func goNext() {
        guard next.isEnabled else { return }
        if step == 4 {
            UserDefaults.standard.set(true,forKey:"onboardingCompletedV1")
            UserDefaults.standard.set(!VoicePermissions.current(shortcutActive:app.hotkey.active).canContinue,forKey:"onboardingLimitedModeV1")
            window.close(); app.showWindow(); return
        }
        step += 1; render()
    }
    @objc private func goBack() { guard app.phase == .idle else { return }; step = max(0,step-1); render() }
    @objc private func pause() {
        if step == 1 && AVCaptureDevice.authorizationStatus(for:.audio) == .authorized { step = 2; render() }
        else if step == 3 { step = 4; render() }
        else { window.close(); app.showWindow() }
    }
    func windowWillClose(_ notification:Notification) { if app.tutorialSession { app.cancelRecording() }; app.tutorialSession = false }
}
