import AppKit
import AVFoundation
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    enum Phase { case idle, preparing, recording, processing }
    let worker = VoiceWorker(), recorder = Recorder(), hotkey = GlobalHotkey(), inserter = TextInserter()
    let deviceMonitor = MicDeviceMonitor()
    let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/freetalk", isDirectory: true)
    lazy var modelSetup = ModelSetup(support:support,resources:Bundle.main.resourceURL!)
    lazy var onboarding = OnboardingController(app:self)
    var modelSetupView: ModelDownloadView?
    lazy var appUpdater = AppUpdater()
    var appUpdateView: AppUpdateView?
    var tutorialSession = false
    lazy var historyStore = VoiceHistoryStore(directory: support)
    lazy var historyWindow = HistoryWindow(store: historyStore)
    var recentHistoryView: RecentHistoryView?
    lazy var meetings = MeetingController(app:self)
    var meetingView: MeetingView?
    lazy var vocabularyStore = VocabularyStore(directory: support)
    lazy var vocabularyWindow = VocabularyWindow(store: vocabularyStore)
    lazy var correctionStore = CorrectionStore(directory: support, vocabulary: vocabularyStore)
    lazy var correctionsWindow = CorrectionsWindow(store: correctionStore)
    let correctionLearner = CorrectionLearner()
    let hud = RecordingHUD()
    let learningHUD = RecordingHUD()
    var undoableLearning: [LearnedCorrection] = []
    var cleanupPicker: NSPopUpButton!
    var layoutPicker: NSPopUpButton!
    var learningButton: NSButton!
    var deviceInfoLabel: NSTextField!
    var startupLabel: NSTextField!
    var settingsTabs: NSTabView!
    var sidebarButtons: [NSButton] = []
    var recordingDevice: MicDevice?
    var preparedDeviceKey: String?
    var preparationRequest = UUID()
    var currentEntry: VoiceHistoryEntry?
    var hudTimer: Timer?
    var hudAnchor: CGRect?
    var targetIssue: String?
    var processingStage = "正在转写…"
    var config: [String: Any] = [:]
    var phase = Phase.idle
    var statusItem: NSStatusItem!
    var menu: NSMenu!
    var recordMenu: NSMenuItem!
    var statusMenu: NSMenuItem!
    var window: NSWindow!
    var statusLabel: NSTextField!
    var permissionsLabel: NSTextField!
    var detailsLabel: NSTextField!
    var modelLabel: NSTextField!
    var resultView: NSTextView!
    var recordButton: NSButton!
    var micPicker: NSPopUpButton!
    var contextButton: NSButton!
    var shortcutButton: NSButton!
    var deviceList: [MicDevice] = []
    var target: InputSnapshot?
    var session = UUID()
    var lastText = "", lastRaw = "", partial = ""
    var statusText = "正在启动…", modelText = "正在加载本地模型…"
    var started = Date(), stopped = Date()
    var timer: Timer?, timeout: Timer?
    var ticks: Timer?
    var seconds = 0.0, level: Float = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let identifier = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: identifier).contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil); return
        }
        NSApp.setActivationPolicy(.accessory)
        do {
            let legacy = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Local Voice",isDirectory:true)
            try LegacyMigration.migrate(from:legacy,to:support)
            if !UserDefaults.standard.bool(forKey:"legacyPreferencesImported"),
               let previous = UserDefaults.standard.persistentDomain(forName:"local.linzekun.voiceinput") {
                for key in ["automaticLearningV1","learnCorrections","cleanupMode","contextEnabled","paragraphLayout","shortcutEnabled","micFollowSystem","micUID"] {
                    if UserDefaults.standard.object(forKey:key) == nil, let value = previous[key] { UserDefaults.standard.set(value,forKey:key) }
                }
                UserDefaults.standard.set(true,forKey:"legacyPreferencesImported")
            }
        } catch { modelText = "旧版数据迁移未完成，原文件已保留：\(error.localizedDescription)" }
        if !UserDefaults.standard.bool(forKey:"automaticLearningV1") {
            UserDefaults.standard.set(true,forKey:"learnCorrections")
            UserDefaults.standard.set(true,forKey:"automaticLearningV1")
        }
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            let data = try Data(contentsOf: support.appendingPathComponent("config.json"))
            config = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        } catch { modelText = "尚未准备模型，请在本地模型页下载。" }
        if let saved = try? Data(contentsOf: support.appendingPathComponent("last-result.json")),
           let item = try? JSONSerialization.jsonObject(with: saved) as? [String: Any] {
            lastText = item["text"] as? String ?? ""; lastRaw = item["raw"] as? String ?? ""
        }
        _ = historyStore
        createMenu(); createWindow(); refreshDevices()
        meetings.connect()
        appUpdater.canInstall = { [weak self] in
            guard let self = self else { return false }
            return self.phase == .idle && !self.inserter.busy && !self.modelSetup.busy && !self.meetings.busy
        }
        appUpdater.onChange = { [weak self] in self?.refreshUI() }
        appUpdater.onFocus = { [weak self] in self?.showUpdates() }
        appUpdater.start()
        modelSetup.onChange = { [weak self] in self?.refreshUI() }
        modelSetup.onComplete = { [weak self] in self?.reloadModel() }
        deviceMonitor.onChange = { [weak self] in
            guard let self = self else { return }
            self.meetings.checkDevice()
            if self.phase == .idle { self.refreshDevices() }
            else if let device = self.recordingDevice, !MicDevices.all().contains(where: { $0.uid == device.uid }) {
                self.preparedDeviceKey = nil; self.preparationRequest = UUID()
                self.cancelRecording(); self.setStatus("录音设备已断开，已取消本次录音；下一次将重新选择设备")
            }
        }
        deviceMonitor.start()
        recorder.onTiming = { [weak self] report in
            guard let self = self else { return }
            let ms = report["first_buffer_ms"] as? Double ?? 0
            self.startupLabel.stringValue = String(format: "上次麦克风启动 %.2f 秒 · %@", ms/1000, report["device"] as? String ?? "")
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]) {
                let url = self.support.appendingPathComponent("last-microphone-start.json")
                try? data.write(to: url, options: .atomic); try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        }
        hud.onStop = { [weak self] in self?.stopRecording() }
        hud.onCancel = { [weak self] in self?.cancelRecording() }
        hud.onCopy = { [weak self] in self?.copyResult() }
        correctionLearner.onLearn = { [weak self] change, anchor in
            guard let self=self else { return }
            self.undoableLearning.append(change); self.hud.hide()
            let count=self.undoableLearning.count
            self.learningHUD.showLearning(title:count == 1 ? "已学会 \(change.alias.term)" : "已学会 \(count) 处改字",detail:"\(change.alias.heard) → \(change.alias.term) · 下次生效",anchor:anchor)
        }
        correctionLearner.onError = { [weak self] error in self?.setStatus("词库未更新：\(error)") }
        learningHUD.onUndo = { [weak self] in
            guard let self=self else { return }
            do { for change in self.undoableLearning.reversed() { try self.correctionStore.undo(change) }; self.setStatus("已撤销刚学到的纠正") }
            catch { self.setStatus("撤销未完成：\(error.localizedDescription)") }
        }
        learningHUD.onDismiss = { [weak self] in self?.undoableLearning.removeAll() }
        worker.onStage = { [weak self] stage in
            guard let self = self, self.phase == .processing else { return }
            self.processingStage = stage == "edit" ? "小模型正在整理…" : "正在完成语音转写…"
            self.setStatus(self.processingStage)
        }
        worker.onState = { [weak self] text, ready in
            guard let self = self else { return }
            self.modelText = text
            if ready && self.phase == .idle {
                self.setStatus(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? "就绪 · 从菜单栏或右 Option 开始" : "模型就绪 · 请先允许麦克风访问")
            }
            if !ready {
                if self.phase != .idle { self.cancelRecording(reload: false) }
                self.setStatus(text)
            }
            self.refreshUI()
        }
        worker.onPartial = { [weak self] text in
            guard let self = self, self.phase == .recording || self.phase == .processing else { return }
            self.partial = text
            if self.tutorialSession { self.onboarding.partial(text) }
            else if self.window.isVisible { self.resultView.string = text }
        }
        hotkey.onToggle = { [weak self] in self?.toggle() }
        hotkey.onEscape = { [weak self] in self?.cancelRecording() }
        updateHotkey()
        ticks = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.phase == .idle && UserDefaults.standard.object(forKey: "shortcutEnabled") as? Bool != false && !self.hotkey.active { self.updateHotkey() }
            self.refreshPermissions()
            self.prepareSelectedDevice()
        }
        reloadModel()
        let first = !UserDefaults.standard.bool(forKey: "onboardingCompletedV1")
        let permissions = VoicePermissions.current(shortcutActive:hotkey.active)
        if first || CommandLine.arguments.contains("--onboarding") { onboarding.show() }
        else if !permissions.microphoneAllowed || (permissions.needsGuidance && !UserDefaults.standard.bool(forKey:"onboardingLimitedModeV1")) { onboarding.showPermissions() }
        else if CommandLine.arguments.contains("--show") { showWindow() }
        UserDefaults.standard.set(true, forKey: "hasOpened")
        // Sleep/device changes must invalidate the frozen insertion target.
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sleeping), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wokeUp), name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(audioChanged), name: .AVAudioEngineConfigurationChange, object: nil)
    }

    func createMenu() {
        let mainMenu = NSMenu(), applicationItem = NSMenuItem(), applicationMenu = NSMenu(title: "freetalk")
        let settings = NSMenuItem(title: "设置与最近结果…", action: #selector(showWindow), keyEquivalent: ","); settings.target = self
        let exit = NSMenuItem(title: "退出 freetalk", action: #selector(quit), keyEquivalent: "q"); exit.target = self
        applicationMenu.addItem(settings)
        let history = NSMenuItem(title: "转写历史（最多500条）…", action: #selector(showHistory), keyEquivalent: "h"); history.target = self
        applicationMenu.addItem(history)
        let guide = NSMenuItem(title:"首次使用引导…",action:#selector(showOnboarding),keyEquivalent:""); guide.target = self; applicationMenu.addItem(guide)
        applicationMenu.addItem(.separator()); applicationMenu.addItem(exit)
        applicationItem.submenu = applicationMenu; mainMenu.addItem(applicationItem); NSApp.mainMenu = mainMenu
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "freetalk 语音输入")
        menu = NSMenu(); menu.delegate = self
        statusMenu = NSMenuItem(title: statusText, action: nil, keyEquivalent: ""); menu.addItem(statusMenu)
        recordMenu = NSMenuItem(title: "开始录音", action: #selector(menuToggle), keyEquivalent: ""); recordMenu.target = self; menu.addItem(recordMenu)
        let cancel = NSMenuItem(title: "取消录音 / 处理", action: #selector(cancelAction), keyEquivalent: ""); cancel.target = self; menu.addItem(cancel)
        menu.addItem(.separator())
        for (title, action) in [("设置与最近结果…", #selector(showWindow)), ("会议资料…",#selector(showMeetings)), ("软件更新…",#selector(showUpdates)), ("首次使用引导…",#selector(showOnboarding)), ("权限设置引导…",#selector(showPermissionGuide)), ("下载本地模型…",#selector(showModels)), ("个人词库…", #selector(showVocabulary)), ("转写历史（最多500条）…", #selector(showHistory)), ("复制最近结果", #selector(copyResult)), ("重新加载模型", #selector(reloadModel)), ("退出 freetalk", #selector(quit))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        statusItem.menu = menu
    }

    func label(_ text: String, size: CGFloat = 13, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text); field.font = .systemFont(ofSize: size); field.textColor = color
        return field
    }
    func button(_ title: String, _ action: Selector) -> NSButton {
        let view = NSButton(title: title, target: self, action: action); view.bezelStyle = .rounded; return view
    }
    func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = .horizontal; stack.spacing = 10; stack.alignment = .centerY; return stack
    }
    func setStatus(_ text: String) { statusText = text; refreshUI() }
    func refreshUI() {
        statusLabel?.stringValue = statusText; statusMenu?.title = statusText; modelLabel?.stringValue = modelText
        let recording = phase == .recording
        recordButton?.title = recording ? "停止并转写" : phase == .preparing ? "取消启动" : "开始录音"
        recordMenu?.title = recordButton?.title ?? "开始录音"
        recordButton?.isEnabled = !appUpdater.installing && !meetings.busy && (recording || phase == .preparing || (phase == .idle && worker.ready && !inserter.busy && !modelSetup.busy))
        recordMenu?.isEnabled = recordButton?.isEnabled ?? false
        micPicker?.isEnabled = phase == .idle && !meetings.busy
        let icon = recording ? "stop.circle.fill" : (phase == .processing ? "ellipsis.circle" : (worker.ready ? "mic" : "mic.slash"))
        statusItem?.button?.image = NSImage(systemSymbolName: icon, accessibilityDescription: "freetalk：\(statusText)")
        statusItem?.button?.contentTintColor = recording ? .systemRed : nil
        if recording {
            let bars = level > 0.04 ? "▂▅▇" : level > 0.012 ? "▂▅" : level > 0.002 ? "▂" : "·"
            statusItem?.button?.title = String(format: " %02d:%02d %@", Int(seconds)/60, Int(seconds)%60, bars)
        } else { statusItem?.button?.title = phase == .processing ? " 整理" : "" }
        statusItem?.button?.toolTip = statusText
        if phase == .preparing || phase == .recording || phase == .processing {
            hud.update(recording: recording, seconds: seconds, level: level, stage: processingStage, targetIssue: targetIssue, anchor: hudAnchor)
        }
        refreshPermissions()
        modelSetupView?.refresh()
        appUpdateView?.refresh()
        meetingView?.refreshState()
        if meetings.recording || meetings.preparing { statusItem?.button?.title = " 会议录音"; statusItem?.button?.contentTintColor = .systemRed }
        else if meetings.processing { statusItem?.button?.title = " 会议整理" }
        if sidebarButtons.count > 4 { sidebarButtons[4].title = appUpdater.hasUpdate ? "软件更新 · 有更新" : "软件更新" }
    }
    func refreshPermissions() {
        let permissions = VoicePermissions.current(shortcutActive:hotkey.active)
        permissionsLabel?.stringValue = "麦克风：\(permissions.microphoneAllowed ? "已允许" : "待授权")  ·  辅助功能：\(permissions.accessibility ? "已允许" : "待授权")  ·  右 Option：\(permissions.shortcutReady ? "可用" : permissions.shortcutEnabled ? "待连接 / 授权" : "未启用")"
        onboarding.refresh()
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        guard window != nil else { return }
        if phase == .idle { updateHotkey(); prepareSelectedDevice() }
        else { refreshPermissions() }
    }
    func updateHotkey() {
        if UserDefaults.standard.object(forKey: "shortcutEnabled") as? Bool != false { hotkey.start() } else { hotkey.stop() }
        refreshPermissions()
    }
    @objc func preferencesChanged() {
        UserDefaults.standard.set(cleanupPicker.indexOfSelectedItem, forKey: "cleanupMode")
        UserDefaults.standard.set(contextButton.state == .on, forKey: "contextEnabled")
        UserDefaults.standard.set(layoutPicker.indexOfSelectedItem == 1, forKey: "paragraphLayout")
        UserDefaults.standard.set(learningButton.state == .on, forKey: "learnCorrections")
        if learningButton.state == .off { correctionLearner.stop() }
        UserDefaults.standard.set(shortcutButton.state == .on, forKey: "shortcutEnabled"); updateHotkey()
    }
    @objc func refreshDevices() {
        guard phase == .idle else { return }
        deviceList = MicDevices.all(); micPicker.removeAllItems()
        let system = MicDevices.selected(uid: nil, devices: deviceList)
        micPicker.addItem(withTitle: "跟随系统输入 · \(system?.name ?? "没有可用麦克风")")
        for device in deviceList { micPicker.addItem(withTitle: device.name) }
        let saved = UserDefaults.standard.string(forKey: "micUID")
        if UserDefaults.standard.object(forKey: "micFollowSystem") == nil { UserDefaults.standard.set(true, forKey: "micFollowSystem") }
        if UserDefaults.standard.bool(forKey: "micFollowSystem") { micPicker.selectItem(at: 0) }
        else if let index = deviceList.firstIndex(where: { $0.uid == saved }) { micPicker.selectItem(at: index+1) }
        else { micPicker.select(nil); setStatus("固定麦克风已断开，请选择跟随系统或其他设备") }
        updateDeviceDescription()
        prepareSelectedDevice()
    }
    @objc func deviceChanged() {
        let index = micPicker.indexOfSelectedItem
        UserDefaults.standard.set(index == 0, forKey: "micFollowSystem")
        if deviceList.indices.contains(index-1) { UserDefaults.standard.set(deviceList[index-1].uid, forKey: "micUID") }
        updateDeviceDescription()
        prepareSelectedDevice()
    }
    func prepareSelectedDevice(force: Bool = false) {
        guard phase == .idle, !meetings.busy, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        let uid = UserDefaults.standard.bool(forKey: "micFollowSystem") ? nil : UserDefaults.standard.string(forKey: "micUID")
        guard let device = MicDevices.selected(uid: uid, devices: deviceList) else { preparedDeviceKey = nil; preparationRequest = UUID(); return }
        let key = "\(device.uid):\(device.id)"
        guard force || preparedDeviceKey != key else { return }
        preparedDeviceKey = key; preparationRequest = UUID(); let request = preparationRequest
        startupLabel?.stringValue = "正在准备 \(device.name)…"
        recorder.prepareDevice(device) { [weak self] result in
            guard let self = self, self.preparationRequest == request else { return }
            switch result {
            case .success(let report):
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]) {
                    let url = self.support.appendingPathComponent("last-microphone-preparation.json")
                    try? data.write(to: url, options: .atomic); try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                }
                if self.phase == .idle { self.startupLabel.stringValue = "麦克风已准备 · 空闲时不采集音频" }
            case .failure:
                if self.phase == .idle { self.startupLabel.stringValue = "暂未准备好，开始录音时将重试" }
            }
        }
    }
    func updateDeviceDescription() {
        let uid = UserDefaults.standard.bool(forKey: "micFollowSystem") ? nil : UserDefaults.standard.string(forKey: "micUID")
        let device = MicDevices.selected(uid: uid, devices: deviceList)
        deviceInfoLabel?.stringValue = device.map { "下次录音：\($0.name) · \($0.transport)" } ?? "未找到所选麦克风"
    }
    @objc func requestMic() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { self.refreshPermissions(); self.prepareSelectedDevice() } }
        } else if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            NSWorkspace.shared.open(VoicePermission.microphone.settingsURL)
        }
    }
    @objc func requestAX() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options); refreshPermissions()
        if !AXIsProcessTrusted() { NSWorkspace.shared.open(VoicePermission.accessibility.settingsURL) }
    }
    @objc func requestKeys() {
        UserDefaults.standard.set(true,forKey:"shortcutEnabled"); shortcutButton?.state = .on
        if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
        updateHotkey()
        if !CGPreflightListenEventAccess() { NSWorkspace.shared.open(VoicePermission.inputMonitoring.settingsURL) }
    }
    @objc func recheckPermissions() { updateHotkey(); prepareSelectedDevice(); refreshPermissions() }
    @objc func revealApplication() { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
    @objc func delayedStart() {
        guard phase == .idle, worker.ready, !inserter.busy, !modelSetup.busy, !meetings.busy, !appUpdater.installing else { return }
        phase = .preparing; session = UUID(); let token = session
        setStatus("5秒后录音，请切回目标输入框并放好光标")
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            guard let self = self, self.session == token, self.phase == .preparing else { return }
            self.phase = .idle; self.toggle()
        }
    }
    func monitorTarget() {
        hudTimer?.invalidate()
        func refreshTarget() {
            self.targetIssue = self.target?.failureReason() ?? (self.target == nil ? "开始时未锁定输入框" : nil)
            if self.targetIssue == nil { self.hudAnchor = self.target?.currentAnchor() }
        }
        refreshTarget()
        hudTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            refreshTarget(); self.refreshUI()
        }
    }
    @objc func menuToggle() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.toggle() } }
    @objc func toggle() {
        guard !meetings.busy else { showMeetings(); return }
        if phase == .recording { stopRecording(); return }
        if phase == .preparing { cancelRecording(reload:false); return }
        guard phase == .idle, worker.ready, !inserter.busy, !modelSetup.busy, !appUpdater.installing else { return }
        tutorialSession = onboarding.wantsTrial
        if tutorialSession { onboarding.begin() }
        correctionLearner.stop(); learningHUD.hide()
        let personalTerms: [String]
        let aliases: [VocabularyAlias]
        do { personalTerms = try vocabularyStore.load(); aliases = try correctionStore.aliases() }
        catch { setStatus("词库读取失败：\(error.localizedDescription)"); showVocabulary(); return }
        let uid = UserDefaults.standard.bool(forKey: "micFollowSystem") ? nil : UserDefaults.standard.string(forKey: "micUID")
        guard let device = MicDevices.selected(uid: uid, devices: MicDevices.all()) else { refreshDevices(); setStatus("所选麦克风不可用，请重新选择"); return }
        recordingDevice = device
        do { target = tutorialSession ? nil : try InputSnapshot.capture() }
        catch { setStatus(error.localizedDescription); return }
        if target?.pid == ProcessInfo.processInfo.processIdentifier { target = nil }
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized { setStatus("请先允许麦克风访问"); onboarding.showPermissions(); return }
        phase = .preparing; session = UUID(); let token = session
        partial = ""; level = 0; seconds = 0; currentEntry = nil
        processingStage = "正在打开麦克风…"; hudAnchor = target?.anchor
        if tutorialSession { hud.hide() } else { hud.show(target: target); monitorTarget() }
        var context = target?.context(enabled: contextButton.state == .on) ?? [:]
        context["personal_terms"] = personalTerms
        context["personal_aliases"] = aliases.map { ["heard":$0.heard,"term":$0.term] }
        context["layout_policy"] = layoutPicker.indexOfSelectedItem == 1 ? "paragraphs" : "minimal"
        setStatus("正在打开麦克风…")
        let policy = ["auto", "always", "fast"][cleanupPicker.indexOfSelectedItem]
        worker.request("begin", ["context": context, "cleanup_policy": policy]) { response in
            guard self.session == token, self.phase == .preparing else { return }
            switch response {
            case .failure(let error): self.phase = .idle; self.hudTimer?.invalidate(); self.hud.finish(success: false, message: error.localizedDescription); self.setStatus(error.localizedDescription)
            case .success:
                self.recorder.onChunk = { [weak self] pcm in
                    guard let self = self, self.session == token else { return }
                    self.worker.request("chunk", ["pcm": pcm.base64EncodedString()]) { response in
                        if case .failure(let error) = response, self.session == token { self.cancelRecording(); self.setStatus(error.localizedDescription) }
                    }
                }
                self.recorder.onLevel = { [weak self] level, seconds in
                    guard let self = self, self.session == token, self.phase == .recording else { return }
                    self.level = level; self.seconds = seconds; self.refreshUI()
                    if seconds >= (self.config["maxRecordingSeconds"] as? Double ?? 90) { self.stopRecording() }
                }
                self.recorder.onError = { [weak self] message in
                    guard let self = self, self.session == token else { return }
                    self.cancelRecording(); self.setStatus(message)
                }
                self.timer = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { _ in
                    guard self.session == token, self.phase == .preparing else { return }
                    self.cancelRecording(); self.setStatus("麦克风启动超时，请检查蓝牙连接或重选设备")
                }
                self.recorder.start(device: device) { response in
                    guard self.session == token, self.phase == .preparing else { return }
                    self.timer?.invalidate()
                    if case .failure(let error) = response { self.phase = .idle; self.hudTimer?.invalidate(); self.hud.finish(success: false, message: error.localizedDescription); self.setStatus(error.localizedDescription); return }
                    self.phase = .recording; self.started = Date()
                    self.setStatus("正在录音 · \(device.name) · 右 Option 停止")
                    self.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                        guard let self = self, self.phase == .recording else { return }
                        let elapsed = Date().timeIntervalSince(self.started)
                        if elapsed > 3 && self.seconds < 0.1 { self.cancelRecording(); self.setStatus("没有收到麦克风音频，请检查设备和权限") }
                        else if elapsed >= (self.config["maxRecordingSeconds"] as? Double ?? 90) + 1 { self.stopRecording() }
                        else if elapsed > 4 && self.level < 0.0001 { self.setStatus("正在录音，但当前没有音量；请检查选中的麦克风") }
                    }
                }
            }
        }
    }
    func stopRecording() {
        guard phase == .recording else { return }
        phase = .processing; stopped = Date(); timer?.invalidate(); let token = session
        processingStage = "正在完成语音转写…"; setStatus(processingStage)
        // Stopping from settings is an explicit return to the still-unchanged target.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
           let target = target, (try? target.resolve(allowBackground: true)) != nil {
            NSRunningApplication(processIdentifier: target.pid)?.activate(options: [])
        }
        recorder.stop { duration, peak in
            guard self.session == token else { return }
            if duration < 0.15 || peak < 0.001 {
                self.phase = .idle; self.hudTimer?.invalidate(); self.hud.finish(success: false, message: "没有检测到语音"); self.setStatus("没有检测到语音，请检查麦克风音量"); return
            }
            self.timeout = Timer.scheduledTimer(withTimeInterval: 35, repeats: false) { _ in
                guard self.session == token, self.phase == .processing else { return }
                let trial = self.tutorialSession
                if !trial { self.lastRaw = self.partial; self.lastText = self.partial; self.saveResult() }
                self.cancelRecording(); self.setStatus(trial ? "试说处理超时，请再试一次。" : "处理超时，已识别的文字保留在最近结果中")
            }
            self.worker.request("finish") { response in
                guard self.session == token, self.phase == .processing else { return }
                self.timeout?.invalidate()
                switch response {
                case .failure(let error):
                    if self.tutorialSession {
                        self.phase = .idle; self.hud.hide(); self.setStatus("试说失败：\(error.localizedDescription)"); return
                    }
                    self.phase = .idle; self.hudTimer?.invalidate(); self.lastRaw = self.partial; self.lastText = self.partial
                    self.saveResult(); self.hud.finish(success: false, message: error.localizedDescription); self.setStatus("转写失败：\(error.localizedDescription)")
                case .success(let result):
                    if self.tutorialSession {
                        self.phase = .idle; self.hud.hide(); self.tutorialSession = false
                        self.onboarding.complete(result,elapsed:Date().timeIntervalSince(self.stopped))
                        self.setStatus("试说完成 · 结果仅在引导中显示"); return
                    }
                    self.lastRaw = result["raw"] as? String ?? ""; self.lastText = result["text"] as? String ?? self.lastRaw
                    self.resultView.string = self.lastText
                    let elapsed = Date().timeIntervalSince(self.stopped)
                    let cleanup = result["cleanup"] as? [String: Any] ?? [:]
                    let modelUsed = cleanup["model_used"] as? Bool ?? false
                    let cleanupLabel = cleanupSummary(cleanup)
                    let routes = cleanup["signals"] as? [String] ?? []
                    self.detailsLabel.stringValue = String(format: "音频 %.1f 秒 · 停止到文字 %.2f 秒 · 整理 %.2f 秒", duration, elapsed, cleanup["seconds"] as? Double ?? 0) + "\n" + cleanupLabel
                    self.currentEntry = VoiceHistoryEntry(id: token.uuidString, createdAt: Date(), text: self.lastText, raw: self.lastRaw,
                        targetApp: self.target?.name ?? "未锁定输入框", insertionStatus: "等待输入", audioSeconds: duration,
                        stopToTextSeconds: elapsed, cleanupSeconds: cleanup["seconds"] as? Double ?? 0, cleanupStatus: cleanupLabel, modelUsed: modelUsed)
                    self.currentEntry?.cleanupRoute = routes.joined(separator:", ")
                    self.currentEntry?.cleanupReason = cleanup["reason"] as? String
                    self.currentEntry?.appliedEdits = cleanup["applied_edits"] as? Int
                    self.currentEntry?.rejectedEdits = (cleanup["rejected_edits"] as? [[String:Any]])?.count
                    self.saveResult()
                    if self.lastText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.phase = .idle; self.hudTimer?.invalidate(); self.hud.finish(success: false, message: "未识别到文字"); self.setStatus("未识别到文字；请检查麦克风或稍后重试"); return
                    }
                    self.processingStage = "正在输入…"; self.setStatus(self.processingStage)
                    self.inserter.insert(self.lastText, into: self.target) { success, message in
                        guard self.session == token else { return }
                        self.phase = .idle; self.hudTimer?.invalidate()
                        self.currentEntry?.insertionStatus = message; self.saveResult()
                        self.hud.finish(success: success, message: message); self.setStatus(message)
                        if success, self.learningButton.state == .on, let target = self.target {
                            self.correctionLearner.start(target:target,inserted:self.lastText,store:self.correctionStore)
                        }
                        self.refreshDevices()
                    }
                }
            }
        }
    }
    func cancelRecording(reload: Bool = true) {
        // Once the paste key has been delivered, cancellation cannot undo it.
        // Wait for verification instead of falsely reporting "nothing inserted".
        guard phase != .idle, !inserter.busy else { return }
        session = UUID(); timer?.invalidate(); timeout?.invalidate(); hudTimer?.invalidate(); hud.hide(); phase = .idle; target = nil
        tutorialSession = false
        recorder.onChunk = nil; recorder.onLevel = nil; recorder.onError = nil; recorder.stop { _,_ in }
        if reload { reloadModel() }
        setStatus("已取消，未插入文字")
    }
    @objc func cancelAction() { cancelRecording() }
    @objc func sleeping() { cancelRecording(); if meetings.recording || meetings.preparing { meetings.stopRecording(process:false) } }
    @objc func wokeUp() { if phase == .idle { refreshDevices(); prepareSelectedDevice(force: true) } }
    @objc func audioChanged() {
        meetings.checkAudio()
        // The engine also announces the intentional device selection at startup.
        // An actual route loss stops the engine; don't cancel a healthy start.
        if phase == .recording { recorder.checkRunning { [weak self] active in
            guard let self = self, self.phase == .recording, !active else { return }
            self.cancelRecording(); self.setStatus("音频设备发生变化，录音已取消，请重选设备")
        } }
    }
    @objc func reloadModel() {
        guard phase == .idle, !modelSetup.busy, !meetings.busy else { return }
        if let data = try? Data(contentsOf: support.appendingPathComponent("config.json")),
           let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { config = settings }
        guard ModelSetup.configured(config) else {
            worker.stop(); modelText = "尚未准备好本地模型"; setStatus("请在「本地模型」中下载运行环境与模型"); return
        }
        if let resource = Bundle.main.resourceURL { worker.start(config: config, resource: resource, support: support) }
    }
    func beginModelDownload(only:String = "all") {
        guard phase == .idle, !inserter.busy, !meetings.busy, !appUpdater.installing else { setStatus("请先结束当前操作，再下载模型。"); return }
        modelSetup.start(config:config,only:only,source:ModelDownloadSource.preferred)
    }
    @objc func showOnboarding() { onboarding.show() }
    @objc func showPermissionGuide() { onboarding.showPermissions() }
    @objc func showUpdates() {
        showWindow(); settingsTabs.selectTabViewItem(at:4)
        for (index,button) in sidebarButtons.enumerated() { button.state = index == 4 ? .on : .off }
    }
    @objc func showModels() {
        showWindow(); settingsTabs.selectTabViewItem(at:3)
        for (index,button) in sidebarButtons.enumerated() { button.state = index == 3 ? .on : .off }
    }
    @objc func showMeetings() {
        showWindow(); settingsTabs.selectTabViewItem(at:5); meetingView?.refreshEntries()
        for (index,button) in sidebarButtons.enumerated() { button.state = index == 5 ? .on : .off }
    }
    @objc func openModelStorage() { NSWorkspace.shared.open(support) }
    func saveResult() {
        if currentEntry == nil && !lastText.isEmpty {
            currentEntry = VoiceHistoryEntry(id: session.uuidString, createdAt: Date(), text: lastText, raw: lastRaw,
                targetApp: target?.name ?? "未锁定输入框", insertionStatus: "处理未完成，保留已识别文字", audioSeconds: seconds,
                stopToTextSeconds: max(0, Date().timeIntervalSince(stopped)), cleanupSeconds: 0, cleanupStatus: "未完成整理", modelUsed: false)
        }
        if let entry = currentEntry {
            historyStore.upsert(entry); recentHistoryView?.refresh()
            if historyWindow.window.isVisible { historyWindow.refresh() }
        }
        let object: [String: Any] = ["text": lastText, "raw": lastRaw, "savedAt": ISO8601DateFormatter().string(from: Date())]
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted,.sortedKeys]) {
            let file = support.appendingPathComponent("last-result.json")
            try? data.write(to: file, options: .atomic); try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }
    @objc func showHistory() { historyWindow.show() }
    @objc func showVocabulary() { vocabularyWindow.show() }
    @objc func showCorrections() { correctionsWindow.show() }
    @objc func copyResult() {
        guard !lastText.isEmpty else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(lastText, forType: .string)
        setStatus("已复制最近结果，可切换到目标输入框粘贴")
    }
    @objc func showRaw() { resultView.string = resultView.string == lastRaw ? lastText : lastRaw }
    @objc func clearResult() { lastText = ""; lastRaw = ""; resultView.string = ""; try? FileManager.default.removeItem(at: support.appendingPathComponent("last-result.json")); setStatus("已清除最近显示，历史记录仍保留") }
    @objc func showWindow() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); refreshUI() }
    @objc func quit() { if meetings.busy { showMeetings(); return }; NSApp.terminate(nil) }
    func menuWillOpen(_ menu: NSMenu) { refreshUI() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationWillTerminate(_ notification: Notification) { modelSetup.cancel(); inserter.restoreBeforeExit(); hotkey.stop(); worker.stop(); recorder.onChunk = nil; recorder.stop { _,_ in } }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
