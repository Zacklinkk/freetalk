import AppKit

extension AppDelegate {
    func card(_ title: String, _ subtitle: String? = nil, views: [NSView]) -> NSView {
        let box = VoiceAppearance.card()
        box.contentViewMargins = NSSize(width: 18, height: 16)
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.addArrangedSubview(label(title, size: 14)); if let subtitle = subtitle { stack.addArrangedSubview(label(subtitle, size: 12, color: .secondaryLabelColor)) }
        for view in views { stack.addArrangedSubview(view) }
        box.contentView = stack; return box
    }
    func settingsPage(_ title: String, subtitle: String, cards: [NSView]) -> NSView {
        let page = NSView(), stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false; page.addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: page.topAnchor, constant: 20), stack.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 26), stack.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -26), stack.bottomAnchor.constraint(lessThanOrEqualTo: page.bottomAnchor, constant: -20)])
        stack.addArrangedSubview(label(title, size: 24)); stack.addArrangedSubview(label(subtitle, color: .secondaryLabelColor))
        for card in cards { stack.addArrangedSubview(card); card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return page
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
        for (index, entry) in [("语音输入","mic"),("最近转写","text.bubble"),("常用词与学习","character.book.closed"),("本地模型","cpu"),("软件更新","arrow.triangle.2.circlepath")].enumerated() {
            let item = NSButton(title: entry.0, target: self, action: #selector(selectSettingsPage(_:)))
            item.image = NSImage(systemSymbolName: entry.1, accessibilityDescription: nil); item.imagePosition = .imageLeading; item.imageHugsTitle = true
            item.bezelStyle = .recessed; item.setButtonType(.pushOnPushOff); item.alignment = .left; item.tag = index
            item.font = .systemFont(ofSize: 13, weight: .medium); nav.addArrangedSubview(item); item.widthAnchor.constraint(equalTo: nav.widthAnchor).isActive = true
            item.heightAnchor.constraint(equalToConstant: 36).isActive = true; sidebarButtons.append(item)
        }
        let footer = label("完全在这台 Mac 上处理\n轻按右 Option 开始录音", size: 11, color: .secondaryLabelColor)
        footer.translatesAutoresizingMaskIntoConstraints = false; sidebar.addSubview(footer)
        NSLayoutConstraint.activate([footer.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 18), footer.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -14), footer.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -22)])

        statusLabel = label(statusText, size: 14)
        recordButton = button("开始录音", #selector(toggle)); recordButton.bezelStyle = .rounded; recordButton.contentTintColor = .controlAccentColor
        let statusCard = card("准备好时，随时开口", views: [statusLabel, row([recordButton,button("5秒后录音",#selector(delayedStart)),button("取消",#selector(cancelAction))])])
        micPicker = NSPopUpButton(); micPicker.target = self; micPicker.action = #selector(deviceChanged); micPicker.setAccessibilityLabel("录音麦克风")
        micPicker.widthAnchor.constraint(lessThanOrEqualToConstant: 550).isActive = true
        deviceInfoLabel = label("", size: 12, color: .secondaryLabelColor); startupLabel = label("结束录音后自动关闭麦克风", size: 12, color: .secondaryLabelColor)
        let micCard = card("麦克风", "跟随系统输入会在每次录音时使用 macOS 当前选中的设备。", views: [row([micPicker,button("刷新",#selector(refreshDevices))]),deviceInfoLabel,startupLabel])
        cleanupPicker = NSPopUpButton(); cleanupPicker.addItems(withTitles: ["自动整理（推荐）","每次使用小模型","仅快速规则"])
        cleanupPicker.selectItem(at: max(0,min(2,UserDefaults.standard.integer(forKey: "cleanupMode")))); cleanupPicker.target = self; cleanupPicker.action = #selector(preferencesChanged); cleanupPicker.setAccessibilityLabel("整理方式")
        layoutPicker = NSPopUpButton(); layoutPicker.addItems(withTitles: ["连续段落 · 仅明确列举时分点","允许适度分段"])
        layoutPicker.selectItem(at: UserDefaults.standard.bool(forKey: "paragraphLayout") ? 1 : 0); layoutPicker.target = self; layoutPicker.action = #selector(preferencesChanged); layoutPicker.setAccessibilityLabel("文字排版")
        contextButton = NSButton(checkboxWithTitle: "用当前输入框辅助辨词", target: self, action: #selector(preferencesChanged))
        contextButton.state = UserDefaults.standard.object(forKey: "contextEnabled") as? Bool == false ? .off : .on
        shortcutButton = NSButton(checkboxWithTitle: "启用右 Option 快捷键", target: self, action: #selector(preferencesChanged))
        shortcutButton.state = UserDefaults.standard.object(forKey: "shortcutEnabled") as? Bool == false ? .off : .on
        let cleanupCard = card("文字与操作", views: [row([label("整理"),cleanupPicker]),row([label("排版"),layoutPicker]),row([contextButton,shortcutButton]),label("保留原意和细节。处理结束后，位置提示会在5秒后消失。",size:12,color:.secondaryLabelColor)])
        permissionsLabel = label("",size:11,color:.secondaryLabelColor)
        let permissionCard = card("系统权限", views: [permissionsLabel,row([button("逐项授权引导",#selector(showPermissionGuide)),button("麦克风",#selector(requestMic)),button("辅助功能",#selector(requestAX)),button("输入监控",#selector(requestKeys))])])
        addSettingsPage(settingsPage("语音输入", subtitle: "说完即写入当前光标位置，保持你的表达。", cards:[statusCard,micCard,cleanupCard,permissionCard]))

        resultView = NSTextView(); resultView.isEditable = false; resultView.isSelectable = true; resultView.isRichText = false
        resultView.font = .systemFont(ofSize:15); resultView.textContainerInset = NSSize(width:16,height:16)
        resultView.isVerticallyResizable = true; resultView.isHorizontallyResizable = false; resultView.autoresizingMask = [.width]; resultView.textContainer?.widthTracksTextView = true
        resultView.string = lastText; resultView.setAccessibilityLabel("最近转写结果")
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .noBorder; scroll.documentView = resultView; scroll.heightAnchor.constraint(equalToConstant:350).isActive = true
        detailsLabel = label("原稿和结果仅在本机保留，最多500条。",size:12,color:.secondaryLabelColor)
        let resultCard = card("最近一次",views:[scroll,detailsLabel,row([button("复制",#selector(copyResult)),button("原稿 / 结果",#selector(showRaw)),button("全部历史",#selector(showHistory)),button("清除显示",#selector(clearResult))])])
        if let container = scroll.superview { scroll.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true }
        addSettingsPage(settingsPage("最近转写",subtitle:"原稿留存，随时对照或复制。",cards:[resultCard]))

        learningButton = NSButton(checkboxWithTitle: "自动学习本次输入后的改字 · 可撤销", target: self, action: #selector(preferencesChanged))
        learningButton.state = UserDefaults.standard.object(forKey:"learnCorrections") as? Bool == false ? .off : .on
        addSettingsPage(settingsPage("常用词与学习",subtitle:"让名字、缩写和项目术语保持正确的拼写。",cards:[
            card("个人词库","每行一个词，保存你常用的写法。下一次录音起生效。",views:[button("管理常用词…",#selector(showVocabulary))]),
            card("从改字学习","默认开启。可靠的短词修正自动加入本机词库，显示5秒撤销提示。\n只检查本次成功输入后的改字；标点、数量、否定和整段改写不学习。",views:[learningButton,button("管理已学会的词…",#selector(showCorrections))]),
            card("使用提示",views:[label("例如：星河知识库、项目名称、SFT。\n专业词在语音识别和文字整理时都会作为辨词参考。",color:.secondaryLabelColor)])]))

        modelLabel = label(modelText,color:.secondaryLabelColor)
        let downloads = ModelDownloadView(app:self); modelSetupView = downloads
        addSettingsPage(settingsPage("本地模型",subtitle:"下载、校验和运行，都可以在这里完成。",cards:[downloads,
            card("运行状态",views:[modelLabel,row([button("重新加载模型",#selector(reloadModel)),button("打开本地文件夹",#selector(openModelStorage)),button("首次使用引导…",#selector(showOnboarding))]),label("模型常驻内存预算上限5 GiB，与磁盘大小不同。建议16 GB内存。\n音频不保存，转写历史和个人词库仅在本机。",size:12,color:.secondaryLabelColor)])]))
        let updates = AppUpdateView(app:self); appUpdateView = updates
        addSettingsPage(settingsPage("软件更新",subtitle:"有新版时在这里提醒，由你决定何时更新。",cards:[updates]))
        sidebarButtons[0].state = .on; settingsTabs.selectTabViewItem(at:0); refreshUI()
    }
    private func addSettingsPage(_ page: NSView) { let item = NSTabViewItem(); item.view = page; settingsTabs.addTabViewItem(item) }
    @objc func selectSettingsPage(_ button: NSButton) { settingsTabs.selectTabViewItem(at:button.tag); for entry in sidebarButtons { entry.state = entry === button ? .on : .off } }
}
