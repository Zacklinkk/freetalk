import AppKit

private final class SettingsDocument: NSView { override var isFlipped: Bool { true } }

extension AppDelegate {
    func card(_ title: String, _ subtitle: String? = nil, views: [NSView]) -> NSView {
        let box = VoiceAppearance.card()
        box.contentViewMargins = NSSize(width: 18, height: 16)
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.addArrangedSubview(label(title, size: 14)); if let subtitle = subtitle { stack.addArrangedSubview(label(subtitle, size: 12, color: .secondaryLabelColor)) }
        for view in views {
            stack.addArrangedSubview(view)
            if view is NSGridView || (view is NSTextField && !(view is NSSecureTextField)) {
                view.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive = true
            }
        }
        box.contentView = stack; return box
    }
    func settingsPage(_ title: String, subtitle: String, cards: [NSView], fillsHeight: Bool = false, scrollable: Bool = false) -> NSView {
        let page: NSView = scrollable ? SettingsDocument() : NSView()
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false; page.addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: page.topAnchor, constant: 20), stack.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 26), stack.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -26), stack.bottomAnchor.constraint(lessThanOrEqualTo: page.bottomAnchor, constant: -20)])
        if fillsHeight || scrollable { stack.bottomAnchor.constraint(equalTo: page.bottomAnchor, constant: -20).isActive = true }
        stack.addArrangedSubview(label(title, size: 24)); stack.addArrangedSubview(label(subtitle, color: .secondaryLabelColor))
        for card in cards { stack.addArrangedSubview(card); card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        if scrollable {
            let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
            page.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = page
            page.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
            return scroll
        }
        return page
    }
    func learningStatusLabel() -> NSTextField {
        let label = label("尚未检查过改字。", size: 12, color: .secondaryLabelColor); learningStatus = label; return label
    }
    func createWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 760), styleMask: [.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView], backing: .buffered, defer: false)
        window.title = "freetalk"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 850, height: 720); window.center()
        let root = window.contentView!, sidebar = NSVisualEffectView()
        sidebar.material = .sidebar; sidebar.blendingMode = .behindWindow; sidebar.state = .followsWindowActiveState
        sidebar.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(sidebar)
        settingsTabs = NSTabView(); settingsTabs.tabViewType = .noTabsNoBorder; settingsTabs.drawsBackground = false
        settingsTabs.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(settingsTabs)
        NSLayoutConstraint.activate([sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor), sidebar.topAnchor.constraint(equalTo: root.topAnchor), sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor), sidebar.widthAnchor.constraint(equalToConstant: 190), settingsTabs.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor), settingsTabs.trailingAnchor.constraint(equalTo: root.trailingAnchor), settingsTabs.topAnchor.constraint(equalTo: root.topAnchor, constant: 30), settingsTabs.bottomAnchor.constraint(equalTo: root.bottomAnchor)])
        let nav = NSStackView(); nav.orientation = .vertical; nav.alignment = .leading; nav.spacing = 8; nav.translatesAutoresizingMaskIntoConstraints = false; sidebar.addSubview(nav)
        NSLayoutConstraint.activate([nav.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 58), nav.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 14), nav.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -14)])
        let brand = label("freetalk", size: 19); nav.addArrangedSubview(brand)
        let tagline = label("你的本地语音输入", size: 11, color: .secondaryLabelColor); nav.addArrangedSubview(tagline)
        nav.setCustomSpacing(24, after: tagline)
        for (index, entry) in [("语音输入","mic"),("最近转写","text.bubble"),("常用词与学习","character.book.closed"),("本地模型","cpu"),("软件更新","arrow.triangle.2.circlepath"),("会议资料","person.3.sequence")].enumerated() {
            let item = SidebarButton(title: entry.0, target: self, action: #selector(selectSettingsPage(_:)))
            item.image = NSImage(systemSymbolName: entry.1, accessibilityDescription: nil); item.imagePosition = .imageLeading; item.imageHugsTitle = true
            item.isBordered = false; item.setButtonType(.pushOnPushOff); item.alignment = .left; item.tag = index
            item.font = .systemFont(ofSize: 13, weight: .medium); nav.addArrangedSubview(item); item.widthAnchor.constraint(equalTo: nav.widthAnchor).isActive = true
            item.heightAnchor.constraint(equalToConstant: 36).isActive = true; sidebarButtons.append(item)
        }
        let footer = label("语音输入默认离线\n会议增强由你选择", size: 11, color: .secondaryLabelColor)
        footer.translatesAutoresizingMaskIntoConstraints = false; sidebar.addSubview(footer)
        NSLayoutConstraint.activate([footer.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 18), footer.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -14), footer.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -22)])

        statusLabel = label(statusText, size: 14)
        recordButton = button("开始录音", #selector(toggle)); recordButton.bezelStyle = .rounded; recordButton.contentTintColor = .controlAccentColor
        let statusCard = card("准备好时，随时开口", views: [statusLabel, row([recordButton,button("5秒后录音",#selector(delayedStart)),button("取消",#selector(cancelAction))])])
        let limit = RecordingLimitView(legacy: { [weak self] in self?.config["maxRecordingSeconds"] }); recordingLimitView = limit
        let limitCard = card("录音时长", views: [limit])
        if let container = limit.superview { limit.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true }
        micPicker = NSPopUpButton(); micPicker.target = self; micPicker.action = #selector(deviceChanged); micPicker.setAccessibilityLabel("录音麦克风")
        micPicker.widthAnchor.constraint(lessThanOrEqualToConstant: 550).isActive = true
        deviceInfoLabel = label("", size: 12, color: .secondaryLabelColor); startupLabel = label("结束录音后自动关闭麦克风", size: 12, color: .secondaryLabelColor)
        let micCard = card("麦克风", "跟随系统输入会在每次录音时使用 macOS 当前选中的设备。", views: [row([micPicker,button("刷新",#selector(refreshDevices))]),deviceInfoLabel,startupLabel])
        cleanupPicker = NSPopUpButton(); cleanupPicker.addItems(withTitles: ["自动整理（推荐）","每次使用小模型","仅快速规则"])
        cleanupPicker.selectItem(at: max(0,min(2,UserDefaults.standard.integer(forKey: "cleanupMode")))); cleanupPicker.target = self; cleanupPicker.action = #selector(preferencesChanged); cleanupPicker.setAccessibilityLabel("整理方式")
        layoutPicker = NSPopUpButton(); layoutPicker.addItems(withTitles: ["连续段落 · 仅明确列举时分点","允许适度分段"])
        layoutPicker.selectItem(at: UserDefaults.standard.bool(forKey: "paragraphLayout") ? 1 : 0); layoutPicker.target = self; layoutPicker.action = #selector(preferencesChanged); layoutPicker.setAccessibilityLabel("文字排版")
        contextButton = NSButton(checkboxWithTitle: "用输入框、应用名称和窗口标题辅助辨词", target: self, action: #selector(preferencesChanged))
        contextButton.state = UserDefaults.standard.object(forKey: "contextEnabled") as? Bool == false ? .off : .on
        shortcutButton = NSButton(checkboxWithTitle: "启用全局快捷键", target: self, action: #selector(preferencesChanged))
        shortcutButton.state = UserDefaults.standard.object(forKey: "shortcutEnabled") as? Bool == false ? .off : .on
        let nearby = NSButton(checkboxWithTitle:"同时参考输入框周围的可见文字（仅本机）",target:self,action:#selector(windowContextChanged(_:)))
        nearby.state = UserDefaults.standard.bool(forKey:"windowContextEnabled") ? .on : .off
        nearbyButton = nearby
        let recognition = NSButton(checkboxWithTitle:"可见文字太少时识别窗口里的文字（仅本机；需要“屏幕录制”权限）",target:self,action:#selector(windowRecognitionChanged(_:)))
        recognition.state = UserDefaults.standard.bool(forKey:"windowOCREnabled") ? .on : .off
        let rich = NSButton(checkboxWithTitle:"列表和分段用富文本粘贴（支持的应用显示为真正的列表）",target:self,action:#selector(richTextChanged(_:)))
        rich.state = UserDefaults.standard.object(forKey:"richTextPaste") as? Bool ?? true ? .on : .off
        let cleanupCard = card("文字整理", "只清理口误、改口和口水词，保留原意和细节。", views: [VoiceAppearance.form([("整理",cleanupPicker)])])
        let detailCard = card("排版与上下文", views: [VoiceAppearance.form([("排版",layoutPicker)]),rich,contextButton,nearby,recognition,
            label("辨词会参考光标前后的文字、选中的文字和网页域名。窗口文字识别只在本机运行，截取的画面不保存、不上传，识别出的文字和可见文字一样不发送到云端；密码管理器的窗口不读取。处理结束后，位置提示会在5秒后消失。",size:12,color:.secondaryLabelColor)])
        dictationShortcutButton = NSButton(title: hotkey.binding.display, target: self, action: #selector(recordDictationShortcut))
        dictationShortcutButton.bezelStyle = .rounded
        meetingShortcutButton = NSButton(title: hotkey.meetingBinding.display, target: self, action: #selector(recordMeetingShortcut))
        meetingShortcutButton.bezelStyle = .rounded
        meetingFollowButton = NSButton(checkboxWithTitle: "会议键跟随语音键", target: self, action: #selector(meetingFollowChanged))
        shortcutTestLabel = label("", size: 12, color: .secondaryLabelColor)
        let shortcutCard = card("快捷键", "轻按单个修饰键，或按住修饰键再按其他键。", views: [
            shortcutButton,
            row([label("语音输入",size:12), dictationShortcutButton]),
            row([label("会议录音",size:12), meetingShortcutButton, meetingFollowButton]),
            makeTranslationControls(),
            row([button("测试快捷键",#selector(testShortcut)), button("恢复默认",#selector(resetHotkeys))]),
            shortcutTestLabel,
            label("测试只检查按键是否送达，不会录音。系统开关已打开但仍提示失效时，请到输入监控中移除后重新添加 freetalk。",size:12,color:.secondaryLabelColor)
        ])
        permissionsLabel = label("",size:11,color:.secondaryLabelColor)
        let permissionCard = card("系统权限与输入兼容性", views: [permissionsLabel,row([button("逐项授权引导",#selector(showPermissionGuide)),button("麦克风",#selector(requestMic)),button("辅助功能",#selector(requestAX)),button("输入监控",#selector(requestKeys))]),button("5秒后测试输入",#selector(testInsertion)),label("切回目标输入框，将插入“freetalk 输入测试”，不会发送。",size:12,color:.secondaryLabelColor)])
        // Everyday settings stay visible; the rest waits behind one disclosure row.
        let advanced = DisclosureSection(title: "专业配置", subtitle: "录音时长、排版与上下文、按应用语气、整理提示词、云端模型、系统权限", key: "voiceAdvancedExpanded",
                                         views: [limitCard,detailCard,makeToneCard(),promptEditor.makeCard(),cloudEditor.makeCard(),permissionCard])
        // A missing permission needs the buttons in there; open it for this session only.
        if VoicePermissions.current(shortcutActive:hotkey.active, shortcutFailure:hotkey.failure).needsGuidance { advanced.reveal() }
        addSettingsPage(settingsPage("语音输入", subtitle: "说完即写入当前光标位置，保持你的表达。", cards:[statusCard,micCard,shortcutCard,cleanupCard,advanced],scrollable:true))

        resultView = NSTextView(); resultView.isEditable = false; resultView.isSelectable = true; resultView.isRichText = false
        resultView.font = .systemFont(ofSize:15); resultView.textContainerInset = NSSize(width:16,height:16)
        resultView.isVerticallyResizable = true; resultView.isHorizontallyResizable = false; resultView.autoresizingMask = [.width]; resultView.textContainer?.widthTracksTextView = true
        resultView.string = lastText; resultView.setAccessibilityLabel("最近转写结果")
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .noBorder; scroll.documentView = resultView; scroll.heightAnchor.constraint(equalToConstant:140).isActive = true
        detailsLabel = label("原稿和结果仅在本机保留，最多500条。",size:12,color:.secondaryLabelColor)
        let resultCard = card("最近一次",views:[scroll,detailsLabel,row([button("复制",#selector(copyResult)),button("原稿 / 结果",#selector(showRaw)),button("全部历史",#selector(showHistory)),button("清除显示",#selector(clearResult))])])
        if let container = scroll.superview { scroll.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true }
        let recent = RecentHistoryView(store: historyStore); recentHistoryView = recent
        recent.onOpen = { [weak self] id in self?.historyWindow.show(entryID: id) }
        let historyCard = card("历史记录", views: [recent])
        historyCard.setContentHuggingPriority(.defaultLow, for: .vertical)
        if let container = recent.superview { recent.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true }
        addSettingsPage(settingsPage("最近转写",subtitle:"最新结果在上方，向下浏览之前的记录。",cards:[resultCard,historyCard],fillsHeight:true))

        learningButton = NSButton(checkboxWithTitle: "自动学习本次输入后的改字 · 可撤销", target: self, action: #selector(preferencesChanged))
        learningButton.state = UserDefaults.standard.object(forKey:"learnCorrections") as? Bool == false ? .off : .on
        addSettingsPage(settingsPage("常用词与学习",subtitle:"让名字、缩写和项目术语保持正确的拼写。",cards:[
            card("个人词库","每行一个词，保存你常用的写法。下一次录音起生效。",views:[button("管理常用词…",#selector(showVocabulary))]),
            card("从改字学习","输入后在同一输入框里改字：改正的词、删掉的口水词和调整的标点都会学习，并显示5秒撤销提示。至少观察 90 秒，每次改字后再等 30 秒，最长 10 分钟。",views:[learningButton,button("管理已学会的词和习惯…",#selector(showCorrections)),learningStatusLabel()]),
            DisclosureSection(title:"专业配置",subtitle:"学习规则、整理规则优化",key:"learningAdvancedExpanded",views:[
                card("学习规则",views:[label("会区分是识别听错还是整理改错：识别听错的词用于语音识别和辨词；整理改错的地方会记下来，供下面的「整理规则优化」使用。数量、否定和整段改写不学习。删掉整理留下的口水词（就是、然后、那个，）、补回被删的语气词、去掉或补上句末句号、在连接词前加逗号、中英文之间加空格，会记成整理习惯：删除和改动类的习惯出现两次后生效，补回的词立即保留；语气词和句号按应用类别分别记录。中文学读音相同或只差一个字母的改字（z/zh、c/ch、n/l、an/ang 这类口音差别），正确写法自动加入词库。重复出现会加强，长期未再出现会自动失效。\n专业词（例如星河知识库、项目名称、SFT）在语音识别和文字整理时都会作为辨词参考。",size:12,color:.secondaryLabelColor)]),
                promptTuning.makeCard()])],scrollable:true))

        modelLabel = label(modelText,color:.secondaryLabelColor)
        let downloads = ModelDownloadView(app:self); modelSetupView = downloads
        addSettingsPage(settingsPage("本地模型",subtitle:"下载、校验和运行，都可以在这里完成。",cards:[downloads,
            card("运行状态",views:[modelLabel,row([button("重新加载模型",#selector(reloadModel)),button("打开本地文件夹",#selector(openModelStorage)),button("首次使用引导…",#selector(showOnboarding))]),label("模型常驻内存约 3.7 GiB（用 1.7B 识别约 5.1 GiB），与磁盘大小不同。建议16 GB内存。\n音频不保存，转写历史和个人词库仅在本机。",size:12,color:.secondaryLabelColor)])],scrollable:true))
        let updates = AppUpdateView(app:self); appUpdateView = updates
        addSettingsPage(settingsPage("软件更新",subtitle:"有新版时在这里提醒，由你决定何时更新。",cards:[updates]))
        let meeting = MeetingView(app:self); meetingView = meeting
        addSettingsPage(settingsPage("会议资料",subtitle:"把讨论变成可回溯的原稿、纪要与脑图。",cards:[meeting],fillsHeight:true))
        sidebarButtons[0].state = .on; settingsTabs.selectTabViewItem(at:0); refreshUI()
    }
    private func addSettingsPage(_ page: NSView) { let item = NSTabViewItem(); item.view = page; settingsTabs.addTabViewItem(item) }
    /// One tone per kind of app, two kinds to a row.
    func makeToneCard() -> NSView {
        var rows: [[NSView]] = [], current: [NSView] = []
        for category in AppCategory.toneChoices {
            let picker = NSPopUpButton(); picker.addItems(withTitles: DictationTone.allCases.map(\.title))
            picker.selectItem(at: DictationTone.allCases.firstIndex(of: DictationTone.chosen(for: category)) ?? 0)
            picker.identifier = NSUserInterfaceItemIdentifier(category.rawValue); picker.target = self; picker.action = #selector(toneChanged(_:))
            picker.setAccessibilityLabel("\(category.title)的语气")
            current += [NSTextField(labelWithString: category.title), picker]
            if current.count == 4 { rows.append(current); current = [] }
        }
        if !current.isEmpty { rows.append(current + [NSGridCell.emptyContentView, NSGridCell.emptyContentView]) }
        let grid = NSGridView(views: rows); grid.rowSpacing = 10; grid.columnSpacing = 12
        for index in [0, 2] { grid.column(at: index).xPlacement = .trailing }
        for index in 0..<grid.numberOfRows { grid.row(at: index).yPlacement = .center }
        return card("按应用调整语气", "自然：按现在的方式整理。正式：去掉句末的呀、啦、哈、呗，结尾补句号。口语：保留语气词，一句话的消息不加句号。", views: [grid,
            label("常用应用和网站已按类别内置：浏览器按网页域名区分，未收录的应用按名称判断。没有列出的类别（代码编辑器、终端、表格、会议等）始终按自然整理。你改字时学到的习惯优先于这里的选择。", size: 12, color: .secondaryLabelColor)])
    }
    @objc func toneChanged(_ sender: NSPopUpButton) {
        guard let id = sender.identifier?.rawValue, let category = AppCategory(rawValue: id), DictationTone.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
        DictationTone.save(DictationTone.allCases[sender.indexOfSelectedItem], for: category)
    }
    @objc func windowContextChanged(_ sender: NSButton) { UserDefaults.standard.set(sender.state == .on,forKey:"windowContextEnabled") }
    @objc func selectSettingsPage(_ button: NSButton) {
        settingsTabs.selectTabViewItem(at:button.tag)
        if button.tag == 1 { recentHistoryView?.refresh() }
        if button.tag == 2 { promptTuning.refresh() }
        if button.tag == 5 { meetingView?.refreshEntries() }
        for entry in sidebarButtons { entry.state = entry === button ? .on : .off }
    }
}
