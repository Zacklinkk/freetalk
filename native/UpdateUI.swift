import AppKit

final class AppUpdateView: NSStackView {
    unowned let app: AppDelegate
    private let status = NSTextField(wrappingLabelWithString:"")
    private let detail = NSTextField(wrappingLabelWithString:"")
    private let lastCheck = NSTextField(wrappingLabelWithString:"")
    private let progress = NSProgressIndicator()
    private let action = NSButton(), cancel = NSButton(), automatic = NSButton()
    private let notes = NSTextView()
    private let noteScroll = NSScrollView()
    init(app: AppDelegate) {
        self.app = app; super.init(frame:.zero)
        orientation = .vertical; alignment = .leading; spacing = 16
        let current = Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "—"
        let versionCard = app.card("freetalk \(current)","从 GitHub Releases 获取正式发布的版本。",views:[])
        addArrangedSubview(versionCard); versionCard.widthAnchor.constraint(equalTo:widthAnchor).isActive = true
        status.font = .systemFont(ofSize:14); status.setAccessibilityLabel("应用更新状态")
        addArrangedSubview(status); status.widthAnchor.constraint(equalTo:widthAnchor).isActive = true
        progress.style = .bar; progress.minValue = 0; progress.maxValue = 1
        addArrangedSubview(progress); progress.widthAnchor.constraint(equalTo:widthAnchor).isActive = true
        detail.font = .monospacedDigitSystemFont(ofSize:12,weight:.regular); detail.textColor = .secondaryLabelColor
        detail.setAccessibilityLabel("应用下载进度"); addArrangedSubview(detail)
        action.target = self; action.action = #selector(primary); action.bezelStyle = .rounded
        cancel.title = "取消更新"; cancel.target = self; cancel.action = #selector(cancelUpdate); cancel.bezelStyle = .rounded
        let releases = NSButton(title:"查看发布记录",target:self,action:#selector(openReleases)); releases.bezelStyle = .inline
        addArrangedSubview(app.row([action,cancel,releases]))
        automatic.title = "自动检查更新（每天）"; automatic.setButtonType(.switch); automatic.target = self; automatic.action = #selector(changeAutomatic)
        addArrangedSubview(automatic)
        lastCheck.font = .systemFont(ofSize:11); lastCheck.textColor = .secondaryLabelColor; addArrangedSubview(lastCheck)
        notes.isEditable = false; notes.isSelectable = true; notes.isRichText = false; notes.font = .systemFont(ofSize:13)
        notes.textContainerInset = NSSize(width:12,height:12); notes.isVerticallyResizable = true; notes.autoresizingMask = [.width]; notes.textContainer?.widthTracksTextView = true
        notes.setAccessibilityLabel("版本说明")
        noteScroll.documentView = notes; noteScroll.hasVerticalScroller = true; noteScroll.borderType = .bezelBorder
        addArrangedSubview(noteScroll); noteScroll.widthAnchor.constraint(equalTo:widthAnchor).isActive = true; noteScroll.heightAnchor.constraint(equalToConstant:170).isActive = true
        addArrangedSubview(app.label("更新只替换应用，已有模型、词库和转写历史继续保留。\n录音、文字处理或模型下载期间不能安装重启。\n当前版本尚未做 Apple 公证；更新后 macOS 可能要求重新关联原有权限。",size:12,color:.secondaryLabelColor))
        refresh()
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    func refresh() {
        let updater = app.appUpdater
        status.stringValue = updater.message; status.textColor = updater.phase == .failed ? .systemRed : .labelColor
        detail.stringValue = updater.progressText; detail.isHidden = detail.stringValue.isEmpty
        progress.isHidden = ![.checking,.downloading,.extracting,.installing].contains(updater.phase)
        if let fraction = updater.fraction { progress.isIndeterminate = false; progress.doubleValue = fraction; progress.stopAnimation(nil) }
        else { progress.isIndeterminate = true; if !progress.isHidden { progress.startAnimation(nil) } else { progress.stopAnimation(nil) } }
        action.title = updater.primaryTitle; action.isEnabled = updater.primaryEnabled
        cancel.isHidden = !updater.canCancel; cancel.isEnabled = updater.canCancel
        automatic.state = updater.automatic ? .on : .off
        lastCheck.stringValue = updater.lastChecked.map { "上次检查：" + DateFormatter.localizedString(from:$0,dateStyle:.short,timeStyle:.short) } ?? "尚未完成版本检查"
        notes.string = updater.notes; noteScroll.isHidden = updater.notes.isEmpty
    }
    @objc private func primary() { app.appUpdater.primaryAction() }
    @objc private func cancelUpdate() { app.appUpdater.cancel() }
    @objc private func changeAutomatic() { app.appUpdater.setAutomatic(automatic.state == .on) }
    @objc private func openReleases() { NSWorkspace.shared.open(URL(string:"https://github.com/Zacklinkk/freetalk/releases")!) }
}
