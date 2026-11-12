import AppKit
import WebKit

private final class MeetingOptionsDocument: NSView { override var isFlipped: Bool { true } }
private final class MeetingOptionsScroll: NSScrollView {
    weak var contentStack: NSStackView?
    override func layout() {
        super.layout()
        guard let document = documentView, let stack = contentStack, contentSize.width > 0 else { return }
        let width = contentSize.width
        if abs(document.frame.width-width) > 1 { document.setFrameSize(NSSize(width:width,height:document.frame.height)) }
        stack.layoutSubtreeIfNeeded()
        let height = max(contentSize.height,stack.fittingSize.height+40)
        if abs(document.frame.height-height) > 1 { document.setFrameSize(NSSize(width:width,height:height)) }
    }
}

final class MeetingView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    unowned let app: AppDelegate
    var controller: MeetingController { app.meetings }
    let enable = NSButton(checkboxWithTitle:"启用会议资料 · 可选功能",target:nil,action:nil)
    let diarization = NSButton(checkboxWithTitle:"区分说话人 · 额外下载约 107 MB",target:nil,action:nil)
    let retain = NSButton(checkboxWithTitle:"完成后保留本机录音",target:nil,action:nil)
    let source = NSPopUpButton()
    let cloudDisclosure = NSButton(title:"云端深度整理与写作 · 可选",target:nil,action:nil)
    let cloudStatus = NSTextField(wrappingLabelWithString:"")
    let writingStyle = NSTextField()
    let tabs = NSTabView()
    let tabPicker = NSSegmentedControl(labels:["录音与资料","选项"],trackingMode:.selectOne,target:nil,action:nil)
    let endpoint = NSTextField(), model = NSTextField(), key = NSSecureTextField()
    let terms = NSTextField()
    let status = NSTextField(wrappingLabelWithString:"")
    let optionsStatus = NSTextField(wrappingLabelWithString:"")
    let optionsProgress = NSProgressIndicator()
    var optionsScroll: NSScrollView?
    let progress = NSProgressIndicator()
    let table = NSTableView(), text = NSTextView()
    let web: WKWebView
    let output = NSTabView()
    let outputPicker = NSSegmentedControl(labels:["基础纪要","原稿","脑图","Agent","深度整理"],trackingMode:.selectOne,target:nil,action:nil)
    let title = NSTextField()
    lazy var shortcutHint = app.label("", size:12, color:.secondaryLabelColor)
    var record: NSButton!, importButton: NSButton!, resumeButton: NSButton!, cancelButton: NSButton!, downloadButton: NSButton!
    var saveCloud: NSButton!
    var saveTermsButton: NSButton!
    var cloudBox: NSStackView!
    var entries: [[String:Any]] = []
    private var selectedID: String? { entries.indices.contains(table.selectedRow) ? entries[table.selectedRow]["id"] as? String : nil }

    init(app: AppDelegate) {
        self.app = app
        let cfg = WKWebViewConfiguration(); cfg.websiteDataStore = .nonPersistent(); cfg.defaultWebpagePreferences.allowsContentJavaScript = false
        web = WKWebView(frame:.zero,configuration:cfg)
        super.init(frame:.zero)
        tabs.tabViewType = .noTabsNoBorder; tabs.drawsBackground = false
        tabPicker.selectedSegment = 0; tabPicker.target = self; tabPicker.action = #selector(tabChanged)
        let layout = stack([enable,tabPicker,tabs]); pin(layout,in:self)
        tabs.widthAnchor.constraint(equalTo:layout.widthAnchor).isActive = true
        tabs.setContentHuggingPriority(.defaultLow,for:.vertical)
        let library = NSTabViewItem(identifier:"library"); library.label = "录音与会议资料"; library.view = makeLibrary(); tabs.addTabViewItem(library)
        let options = NSTabViewItem(identifier:"options"); options.label = "会议选项与模型"; options.view = makeOptions(); tabs.addTabViewItem(options)
        enable.target = self; enable.action = #selector(enableChanged)
        enable.state = controller.enabled ? .on : .off
        controller.onChange = { [weak self] in self?.refreshState() }
        controller.onComplete = { [weak self] id in self?.refreshEntries(select:id) }
        refreshEntries(); refreshState()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func stack(_ views: [NSView], spacing: CGFloat = 12) -> NSStackView {
        let s = NSStackView(views:views); s.orientation = .vertical; s.alignment = .leading; s.spacing = spacing; return s
    }
    private func pin(_ stack: NSView, in host: NSView) {
        stack.translatesAutoresizingMaskIntoConstraints = false; host.addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo:host.topAnchor,constant:16),stack.leadingAnchor.constraint(equalTo:host.leadingAnchor,constant:16),stack.trailingAnchor.constraint(equalTo:host.trailingAnchor,constant:-16),stack.bottomAnchor.constraint(equalTo:host.bottomAnchor,constant:-16)])
    }
    private func action(_ title: String, _ selector: Selector) -> NSButton { let b = NSButton(title:title,target:self,action:selector); b.bezelStyle = .rounded; return b }
    private func makeLibrary() -> NSView {
        let host = NSView()
        title.placeholderString = "会议标题（可选）"; title.setAccessibilityLabel("会议标题")
        record = action("开始会议录音",#selector(toggleRecord)); importButton = action("导入录音…",#selector(importAudio)); cancelButton = action("停止处理",#selector(cancel))
        progress.minValue = 0; progress.maxValue = 1; progress.style = .bar; progress.isIndeterminate = false
        status.font = .systemFont(ofSize:12); status.textColor = .secondaryLabelColor
        let columns = NSStackView(); columns.orientation = .horizontal; columns.spacing = 14; columns.alignment = .top
        let left = NSScrollView(); left.hasVerticalScroller = true; left.borderType = .noBorder; left.drawsBackground = false; table.backgroundColor = .clear
        let column = NSTableColumn(identifier:NSUserInterfaceItemIdentifier("meeting")); column.width = 165; table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 64; table.dataSource = self; table.delegate = self; table.allowsEmptySelection = false
        table.setAccessibilityLabel("会议资料列表"); left.documentView = table
        left.widthAnchor.constraint(equalToConstant:180).isActive = true; columns.addArrangedSubview(left)
        outputPicker.selectedSegment = 0; outputPicker.target = self; outputPicker.action = #selector(outputChanged)
        text.isEditable = false; text.isSelectable = true; text.font = .systemFont(ofSize:13); text.textContainerInset = NSSize(width:12,height:12)
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false; text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView(); scroll.documentView = text; scroll.hasVerticalScroller = true
        output.tabViewType = .noTabsNoBorder; output.drawsBackground = false
        let textTab = NSTabViewItem(); textTab.view = scroll; output.addTabViewItem(textTab)
        let webTab = NSTabViewItem(); webTab.view = web; output.addTabViewItem(webTab)
        let right = stack([outputPicker,output]); columns.addArrangedSubview(right)
        NSLayoutConstraint.activate([left.heightAnchor.constraint(equalTo:columns.heightAnchor),right.heightAnchor.constraint(equalTo:columns.heightAnchor),right.widthAnchor.constraint(equalTo:columns.widthAnchor,constant:-194),output.widthAnchor.constraint(equalTo:right.widthAnchor)])
        output.setContentHuggingPriority(.defaultLow,for:.vertical); columns.setContentHuggingPriority(.defaultLow,for:.vertical)
        resumeButton = action("继续处理",#selector(resume))
        let controls = app.row([action("刷新",#selector(refresh)),resumeButton,action("导出资料…",#selector(export)),action("打开文件夹",#selector(reveal))])
        let all = stack([shortcutHint,title,app.row([record,importButton,cancelButton]),status,progress,columns,controls])
        pin(all,in:host)
        for view in [title,status,progress,columns] { view.widthAnchor.constraint(equalTo:all.widthAnchor).isActive = true }
        return host
    }
    private func makeOptions() -> NSView {
        let host = MeetingOptionsDocument(frame:NSRect(x:0,y:0,width:600,height:900))
        diarization.state = controller.settings["diarization"] as? Bool == true ? .on : .off; diarization.target = self; diarization.action = #selector(optionsChanged)
        retain.state = controller.settings["retain_audio"] as? Bool == true ? .on : .off; retain.target = self; retain.action = #selector(optionsChanged)
        source.addItems(withTitles:["Hugging Face 官方","HF-Mirror 镜像"]); source.selectItem(at:ModelDownloadSource.preferred == .mirror ? 1 : 0)
        downloadButton = action("下载 / 校验说话人模型",#selector(download))
        endpoint.placeholderString = "https://你的服务/v1"; endpoint.setAccessibilityLabel("会议云端 API 地址"); endpoint.stringValue = controller.settings["base_url"] as? String ?? ""
        model.placeholderString = "服务提供的模型名称"; model.setAccessibilityLabel("会议云端模型名称"); model.stringValue = controller.settings["model"] as? String ?? ""
        key.placeholderString = "API Key · 留空保留钥匙串中的密钥"; key.setAccessibilityLabel("会议云端 API Key")
        saveCloud = action("保存云端配置",#selector(saveCloudSettings))
        terms.placeholderString = "会议术语，逗号分隔，如：SFT、项目名称"; terms.setAccessibilityLabel("会议术语")
        terms.stringValue = (controller.settings["terms"] as? [String] ?? []).joined(separator:", ")
        writingStyle.placeholderString = "例如：整理为项目周报，先结论，再列决定、行动项和待确认事项"
        writingStyle.stringValue = controller.settings["writing_style"] as? String ?? ""
        writingStyle.setAccessibilityLabel("深度整理写作要求")
        cloudDisclosure.setButtonType(.pushOnPushOff); cloudDisclosure.isBordered = false; cloudDisclosure.imagePosition = .imageLeading; cloudDisclosure.font = .systemFont(ofSize:13,weight:.medium); cloudDisclosure.setAccessibilityLabel("展开云端深度整理与写作配置")
        cloudDisclosure.target = self; cloudDisclosure.action = #selector(toggleCloud)
        cloudDisclosure.state = controller.cloudConfigured ? .on : .off
        cloudStatus.font = .systemFont(ofSize:12); cloudStatus.textColor = .secondaryLabelColor
        let form = VoiceAppearance.form([("API 地址",endpoint),("模型名称",model),("API Key",key),("写作要求",writingStyle)])
        let explanation = app.label("保存配置后，新会议会先在本机生成基础纪要与脑图，再把基础纪要和相关引文发送到你指定的服务，生成独立的深度整理版本。支持 OneAPI 等 OpenAI 兼容服务。音频不上传；密钥存入 macOS 钥匙串。",size:12,color:.secondaryLabelColor)
        cloudBox = stack([form,app.row([saveCloud,action("停用云端增强",#selector(disableCloud))]),explanation])
        form.widthAnchor.constraint(equalTo:cloudBox.widthAnchor).isActive = true
        explanation.widthAnchor.constraint(equalTo:cloudBox.widthAnchor).isActive = true
        let privacy = app.label("本地：使用「本地模型」页选定的语音识别模型 + 4B 整理模型；1.7B 识别更准，转写时间约为 0.6B 的 2.5 倍。\n说话人区分：Nemotron-3 8bit，约 107 MB，最多 8 个匿名说话人；不识别真实身份，重叠语音可能需要核对。\n录音处理中临时保存；成功后按开关保留或删除。失败/中止时保留，便于继续处理。会议资料单独保存，不套用普通转写的 500 条上限。",size:12,color:.secondaryLabelColor)
        let agent = app.label("Agent 可以通过 CLI 读取 JSON、搜索原文、导出 Markdown 与脑图。读取不加载模型、不需要云端密钥，也不会执行会议中的行动项。",size:12,color:.secondaryLabelColor)
        optionsStatus.font = .systemFont(ofSize:12); optionsStatus.textColor = .secondaryLabelColor
        optionsProgress.minValue = 0; optionsProgress.maxValue = 1; optionsProgress.style = .bar; optionsProgress.isIndeterminate = false
        saveTermsButton = action("保存术语",#selector(saveTerms))
        let termsRow = app.row([terms,saveTermsButton])
        let all = stack([app.label("本地基础整理始终保留",size:18),diarization,app.row([source,downloadButton]),optionsStatus,optionsProgress,retain,termsRow,privacy,cloudDisclosure,cloudStatus,cloudBox,agent,action("复制 CLI 路径",#selector(copyCLI)),action("查看说话人模型与许可",#selector(openModelSource))],spacing:10)
        terms.widthAnchor.constraint(greaterThanOrEqualToConstant:160).isActive = true
        terms.setContentHuggingPriority(.defaultLow,for:.horizontal)
        saveTermsButton.setContentCompressionResistancePriority(.required,for:.horizontal)
        all.translatesAutoresizingMaskIntoConstraints = false; host.addSubview(all)
        NSLayoutConstraint.activate([all.topAnchor.constraint(equalTo:host.topAnchor,constant:20),all.leadingAnchor.constraint(equalTo:host.leadingAnchor,constant:18),all.trailingAnchor.constraint(equalTo:host.trailingAnchor,constant:-18)])
        for v in [privacy,agent,cloudBox!,optionsStatus,optionsProgress,termsRow] { v.widthAnchor.constraint(equalTo:all.widthAnchor).isActive = true }
        cloudStatus.widthAnchor.constraint(equalTo:all.widthAnchor).isActive = true
        let scroll = MeetingOptionsScroll(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.documentView = host; scroll.contentStack = all
        optionsScroll = scroll
        return scroll
    }
    func refreshState() {
        shortcutHint.stringValue = "\(app.hotkey.meetingBinding.display) 开始或结束会议录音"
        let running = controller.busy
        enable.isEnabled = !running; enable.state = controller.enabled ? .on : .off
        let ready = controller.enabled && !running && app.phase == .idle && app.worker.ready && !app.modelSetup.busy && !app.appUpdater.installing
        record.title = controller.recording || controller.preparing ? "结束并生成资料" : "开始会议录音"
        record.isEnabled = ready || controller.recording || controller.preparing; importButton.isEnabled = ready
        resumeButton.isEnabled = ready && selectedID != nil; cancelButton.isEnabled = running
        title.isEnabled = !running
        for v in [diarization,retain,source] as [NSControl] { v.isEnabled = controller.enabled && !running }
        downloadButton.isEnabled = controller.enabled && diarization.state == .on && !running && app.phase == .idle
        cloudBox.isHidden = cloudDisclosure.state != .on
        cloudDisclosure.image = NSImage(systemSymbolName:cloudDisclosure.state == .on ? "chevron.down" : "chevron.right",accessibilityDescription:nil)
        cloudStatus.stringValue = controller.cloudConfigured ? "已配置：本地基础整理 + 云端深度整理" : "未配置：仅在本机生成基础纪要与脑图"
        for v in [endpoint,model,key,writingStyle,saveCloud] as [NSControl] { v.isEnabled = controller.enabled && !running }
        terms.isEnabled = controller.enabled && !running; saveTermsButton.isEnabled = terms.isEnabled
        if controller.downloads.busy { status.stringValue = controller.downloads.message + "\n" + controller.downloads.progressText; progress.doubleValue = controller.downloads.fraction ?? 0 }
        else { status.stringValue = controller.message; progress.doubleValue = controller.fraction ?? 0 }
        progress.isHidden = !running
        optionsStatus.stringValue = controller.downloads.busy || controller.downloads.failed ? controller.downloads.message + " " + controller.downloads.progressText : controller.message
        optionsProgress.isHidden = !controller.downloads.busy; optionsProgress.doubleValue = controller.downloads.fraction ?? 0
        optionsScroll?.needsLayout = true
    }
    func refreshEntries(select: String? = nil) {
        let previous = select ?? selectedID; entries = controller.entries(); table.reloadData()
        if let id = previous, let i = entries.firstIndex(where: { $0["id"] as? String == id }) { table.selectRowIndexes(IndexSet(integer:i),byExtendingSelection:false) }
        else if !entries.isEmpty { table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false) }
        showSelected(); refreshState()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = entries[row]; let state = item["status"] as? String ?? ""
        let stateText = ["complete":"已完成","created":"待处理","processing":"处理中","recording":"录音中","failed":"需重试","interrupted":"已暂停"][state] ?? state
        let label = NSTextField(wrappingLabelWithString:(item["title"] as? String ?? "会议") + "\n" + stateText + " · " + String((item["created_at"] as? String ?? "").prefix(10)))
        label.maximumNumberOfLines = 3; label.font = .systemFont(ofSize:12); return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) { showSelected(); refreshState() }
    private func showSelected() {
        guard let id = selectedID else { text.string = "尚无会议资料。启用后可以导入录音，或开始一次会议录音。"; output.selectTabViewItem(at:0); return }
        let directory = controller.directory(id)
        if outputPicker.selectedSegment <= 2 {
            let file = directory.appendingPathComponent(["minutes.html","transcript.html","mindmap.html"][max(0,outputPicker.selectedSegment)])
            if FileManager.default.fileExists(atPath:file.path) { web.loadFileURL(file,allowingReadAccessTo:directory); output.selectTabViewItem(at:1); return }
        }
        if outputPicker.selectedSegment == 4 {
            let manifest = entries[table.selectedRow]
            guard manifest["deep_status"] as? String == "complete" else {
                text.string = manifest["deep_error"] as? String ?? "尚无深度整理。可在“选项”中展开云端配置；本地基础资料始终独立保留。"
                output.selectTabViewItem(at:0); return
            }
            web.loadFileURL(directory.appendingPathComponent("deep.html"),allowingReadAccessTo:directory); output.selectTabViewItem(at:1); return
        }
        let names = ["minutes.md","transcript.md","mindmap.mmd","agent-context.md","deep.md"]
        text.string = (try? String(contentsOf:directory.appendingPathComponent(names[max(0,outputPicker.selectedSegment)]),encoding:.utf8)) ?? "这份资料尚未生成。未完成的录音可以选择“继续处理”。原稿进度保留在本地文件夹。"
        output.selectTabViewItem(at:0)
    }
    @objc private func tabChanged() { tabs.selectTabViewItem(at:tabPicker.selectedSegment) }
    @objc private func toggleCloud() { refreshState() }
    @objc private func disableCloud() {
        controller.settings["cloud_enabled"] = false; controller.settings["summary_mode"] = "local"
        do { try controller.saveSettings(); controller.showMessage("已停用云端增强，新会议仅在本机处理。已生成资料保留。") } catch { controller.showError(error) }
        refreshState()
    }
    @objc private func enableChanged() {
        controller.settings["enabled"] = enable.state == .on
        do { try controller.saveSettings() } catch { controller.showError(error) }
        refreshState()
    }
    @objc private func optionsChanged() {
        controller.settings["diarization"] = diarization.state == .on
        controller.settings["retain_audio"] = retain.state == .on
        do { try controller.saveSettings() } catch { controller.showError(error) }
        refreshState()
    }
    @objc private func saveCloudSettings() {
        do {
            let base = endpoint.stringValue.trimmingCharacters(in:.whitespacesAndNewlines).trimmingCharacters(in:CharacterSet(charactersIn:"/"))
            guard let url = URL(string:base), let host = url.host, url.scheme == "https" || (url.scheme == "http" && ["localhost","127.0.0.1","::1"].contains(host)),
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { throw VoiceError.message("请输入有效的 HTTPS API 地址，不要将密钥写在 URL 中") }
            guard !model.stringValue.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw VoiceError.message("请输入服务提供的模型名称") }
            if !key.stringValue.isEmpty { try MeetingKeychain.save(key.stringValue,endpoint:base); key.stringValue = "" }
            guard !(MeetingKeychain.read(endpoint:base) ?? "").isEmpty else { throw VoiceError.message("请输入 API Key 后保存") }
            controller.settings["cloud_enabled"] = true
            controller.settings["summary_mode"] = "local"
            controller.settings["writing_style"] = String(writingStyle.stringValue.prefix(600))
            controller.settings["base_url"] = base; controller.settings["model"] = model.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
            try controller.saveSettings()
            controller.showMessage("云端增强已启用。下次先生成本地基础资料，再发送纪要和引文进行深度整理。")
        } catch { controller.showError(error) }
        refreshState()
    }
    @objc private func download() {
        guard controller.enabled, diarization.state == .on, !controller.busy else { return }
        controller.downloads.start(config:app.config,only:"meetingDiarizationModel",source:source.indexOfSelectedItem == 1 ? .mirror : .official)
    }
    @objc private func toggleRecord() { if controller.recording || controller.preparing { controller.stopRecording() } else { controller.startRecording(title:title.stringValue) } }
    @objc private func importAudio() { controller.importAudio() }
    @objc private func cancel() { controller.cancel() }
    @objc private func refresh() { refreshEntries() }
    @objc private func outputChanged() { showSelected() }
    @objc private func resume() {
        guard let id = selectedID else { return }
        do { try controller.available(); controller.process(id) } catch { controller.showError(error) }
    }
    @objc private func reveal() { if let id = selectedID { NSWorkspace.shared.open(controller.directory(id)) } }
    @objc private func export() {
        guard let id = selectedID else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.prompt = "导出到这里"
        panel.message = "导出原稿、纪要、脑图和 agent 说明。不会包含录音或 API Key。"
        panel.beginSheetModal(for:app.window) { [weak self] response in
            guard let self = self, response == .OK, let destination = panel.url?.appendingPathComponent("freetalk-"+id) else { return }
            do {
                guard !FileManager.default.fileExists(atPath:destination.path) else { throw VoiceError.message("目标已存在，请选择其他文件夹") }
                try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
                for name in ["manifest.json","transcript.jsonl","minutes.json","minutes.md","minutes.html","transcript.md","transcript.html","mindmap.json","mindmap.mmd","mindmap.html","agent-context.md"] {
                    let file = self.controller.directory(id).appendingPathComponent(name)
                    if FileManager.default.fileExists(atPath:file.path) { try FileManager.default.copyItem(at:file,to:destination.appendingPathComponent(name)) }
                }
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch { self.controller.showError(error) }
        }
    }
    @objc private func copyCLI() {
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/bin/freetalk").path
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString("'" + path.replacingOccurrences(of:"'",with:"'\\''") + "' meetings list",forType:.string)
    }
    @objc private func saveTerms() {
        guard controller.enabled, !controller.busy else { return }
        controller.settings["terms"] = Array(terms.stringValue.components(separatedBy:CharacterSet(charactersIn:",，、\n")).map { $0.trimmingCharacters(in:.whitespacesAndNewlines) }.filter { !$0.isEmpty }.prefix(80))
        do { try controller.saveSettings(); controller.showMessage("会议术语已保存，下次转写时生效。") } catch { controller.showError(error) }
    }
    @objc private func openModelSource() { if let url = controller.downloads.models.first?.pageURL(source:source.indexOfSelectedItem == 1 ? .mirror : .official) { NSWorkspace.shared.open(url) } }
}
