import AppKit

/// 夜间整理: once a night, while the Mac is idle, build the user profile from
/// the dictation history and tune the cleanup rules. Each step has its own
/// switch; the card shows what the last run did and can run it now.
final class NightlyMaintenance: NSObject {
    unowned let app: AppDelegate
    private let enabledBox = NSButton(checkboxWithTitle: "开启夜间整理（每晚 00:30–06:00 之间，空闲 15 分钟后运行一次）", target: nil, action: nil)
    private let profileBox = NSButton(checkboxWithTitle: "画像与转写热词：从口述历史推断你常谈的领域，把领域里的专业词加入转写热词", target: nil, action: nil)
    private let tuningBox = NSButton(checkboxWithTitle: "整理规则优化：用插入后又被你改过的口述优化整理规则（同下方「整理规则优化」）", target: nil, action: nil)
    private let profileLabel = NSTextField(wrappingLabelWithString: ""), reportLabel = NSTextField(wrappingLabelWithString: "")
    private var runButton: NSButton!, clearButton: NSButton!
    private var timer: Timer?
    /// A step is waiting on the worker; dictation waits until it finishes.
    private(set) var busy = false
    /// Waiting for the Keychain before 立即运行 starts; dictation is not blocked.
    private var reading = false
    init(app: AppDelegate) { self.app = app; super.init() }

    func makeCard() -> NSView {
        let s = NightlySettings.load()
        for (box, on) in [(enabledBox, s.enabled), (profileBox, s.profile), (tuningBox, s.tuning)] {
            box.target = self; box.action = #selector(changed); box.state = on ? .on : .off
        }
        for field in [profileLabel, reportLabel] { field.font = .systemFont(ofSize: 12); field.textColor = .secondaryLabelColor }
        runButton = app.button("立即运行", #selector(runNow)); runButton.target = self
        clearButton = app.button("清除画像", #selector(clearProfile)); clearButton.target = self
        refresh()
        return app.card("夜间整理", "电脑空闲时，用强模型整理你的使用记录，让第二天的识别和整理更贴近你。", views: [
            enabledBox, profileBox, tuningBox, profileLabel, reportLabel, app.row([runButton, clearButton]),
            app.label("画像只发送口述里反复出现的词和次数（例如“模型 39 次”），不发送句子和音频；得到的专业词只作为本机转写的热词，不会直接改写文字。整理规则优化发送的内容见下方卡片。都使用「语音输入 → 专业配置 → 云端模型」里的强模型。为了不在夜里弹出钥匙串授权，当天启动后没有读到过密钥就跳过。", size: 11, color: .secondaryLabelColor)])
    }

    func refresh() {
        guard runButton != nil else { return }
        let s = NightlySettings.load(), cloud = CloudEditorSettings.load()
        profileBox.isEnabled = s.enabled; tuningBox.isEnabled = s.enabled
        if let profile = UserProfile.load(app.support) {
            let formatter = DateFormatter(); formatter.dateFormat = "M月d日"
            profileLabel.stringValue = "画像（\(formatter.string(from: profile.createdAt))，来自 \(profile.dictations) 条口述）：\(profile.domains.joined(separator: "、"))\n转写热词 \(profile.terms.count) 个：\(profile.terms.prefix(24).joined(separator: "、"))\(profile.terms.count > 24 ? "…" : "")" + (s.usesProfile ? "" : "\n画像步骤已关闭，转写暂不使用这些词。")
        } else {
            profileLabel.stringValue = "还没有画像。口述满 \(UserProfile.minimumDictations) 条后，夜间整理会生成一份。"
        }
        let report = UserDefaults.standard.string(forKey: "nightlyReport")
        reportLabel.stringValue = busy ? "正在运行…（期间暂停口述）" : !cloud.serviceReady ? "需要先在「云端模型」里填好服务、模型和密钥。" : report.map { "上次运行：\($0)" } ?? "还没有运行过。"
        runButton.isEnabled = !busy && !reading && s.active && cloud.serviceReady && app.worker.ready && !app.promptTuning.busy
        clearButton.isEnabled = !busy && UserProfile.load(app.support) != nil
    }

    @objc private func changed() {
        NightlySettings(enabled: enabledBox.state == .on, profile: profileBox.state == .on, tuning: tuningBox.state == .on).save()
        let cloud = CloudEditorSettings.load()
        if cloud.readsKeyAtLaunch && cloud.serviceReady { CloudCredentialStore.prefetch(cloud.baseURL) }
        refresh(); app.cloudSettingsChanged()
    }

    @objc private func clearProfile() { UserProfile.clear(app.support); refresh() }

    /// Check every ten minutes whether tonight's run is due.
    func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in self?.runIfDue() }
    }

    /// A Keychain prompt at night would wait for nobody, so a key that was
    /// never read this launch skips the night.
    func runIfDue(now: Date = Date()) {
        let s = NightlySettings.load(), cloud = CloudEditorSettings.load(), defaults = UserDefaults.standard
        guard s.active, cloud.serviceReady, idle,
              NightlySettings.due(now: now, lastRun: defaults.object(forKey: "nightlyLastRun") as? Date, lastDictation: app.historyStore.entries.first?.createdAt) else { return }
        defaults.set(now, forKey: "nightlyLastRun")
        guard let credentials = CloudCredentialStore.cached(cloud.baseURL) else { finish(["钥匙串尚未授权，今晚跳过；白天测试一次云端连接即可"]); return }
        run(s, credentials: credentials, force: false)
    }

    @objc func runNow() {
        let cloud = CloudEditorSettings.load()
        reading = true; refresh(); reportLabel.stringValue = "正在读取钥匙串中的密钥…（如果 macOS 询问，请选择“始终允许”）"
        CloudCredentialStore.prefetch(cloud.baseURL) { [weak self] credentials in
            guard let self = self else { return }
            self.reading = false
            guard let credentials = credentials else { self.reportLabel.stringValue = "无法从钥匙串读取 API Key：请在「云端模型」里重新保存。"; self.refresh(); return }
            guard self.idle else { self.reportLabel.stringValue = "正在口述或处理会议，空闲后再试。"; self.refresh(); return }
            self.run(NightlySettings.load(), credentials: credentials, force: true)
        }
    }

    /// Nothing else uses the worker. A tuning proposal waiting for the user does
    /// not stop the profile step; the tuning step skips itself instead.
    private var idle: Bool {
        app.worker.ready && app.phase == .idle && !app.meetings.busy && !app.inserter.busy && !app.modelSetup.busy
            && !app.appUpdater.installing && !app.promptEditor.checking && !app.promptTuning.busy && !busy && !reading
    }

    private func run(_ s: NightlySettings, credentials: CloudCredentials, force: Bool) {
        busy = true; refresh()
        let tune = { [weak self] (lines: [String]) in
            guard let self = self else { return }
            guard s.tuning else { self.finish(lines); return }
            self.app.promptTuning.nightly(credentials: credentials, force: force) { line in self.finish(lines + ["整理规则：\(line)"]) }
        }
        guard s.profile else { tune([]); return }
        buildProfile(credentials: credentials, force: force) { line in tune(["画像：\(line)"]) }
    }

    private func finish(_ lines: [String]) {
        busy = false
        let formatter = DateFormatter(); formatter.dateFormat = "M月d日 HH:mm"
        UserDefaults.standard.set("\(formatter.string(from: Date()))\n" + lines.joined(separator: "\n"), forKey: "nightlyReport")
        refresh(); app.promptTuning.refresh()
    }

    /// Count words on this Mac, send the counts, keep the answer if it has terms.
    private func buildProfile(credentials: CloudCredentials, force: Bool, done: @escaping (String) -> Void) {
        // A translation's text is in the other language; it says nothing about how the user speaks.
        let entries = app.historyStore.entries.filter { $0.learningStop != "翻译输入不学习" }
        guard entries.count >= UserProfile.minimumDictations else { done("口述还不到 \(UserProfile.minimumDictations) 条，跳过"); return }
        let previous = UserProfile.load(app.support)
        guard force || UserProfile.due(previous, history: entries.map(\.createdAt)) else { done("新口述不到 \(UserProfile.refreshAfter) 条，沿用现有画像"); return }
        let texts = entries.map { $0.editedText ?? $0.text }, cloud = CloudEditorSettings.load(), support = app.support
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let statistics = UserProfile.statistics(texts).map { ["term": $0.term, "count": $0.count] as [String: Any] }
            DispatchQueue.main.async {
                guard let self = self else { return }
                let payload: [String: Any] = ["cloud": cloud.payload(with: credentials, strong: true), "statistics": statistics, "dictations": texts.count]
                self.app.worker.request("build_profile", payload) { response in
                    switch response {
                    case .failure(let error): done("未完成：\(CloudEditorSettings.describe(fallback: error.localizedDescription))")
                    case .success(let value):
                        let terms = value["terms"] as? [String] ?? [], domains = value["domains"] as? [String] ?? []
                        guard !terms.isEmpty else { done("没有得出可靠的画像，保留原来的"); return }
                        let profile = UserProfile(createdAt: Date(), model: cloud.strongName, dictations: texts.count, domains: domains, terms: terms)
                        do { try profile.save(support); done("已更新：\(domains.joined(separator: "、"))；\(terms.count) 个转写热词") }
                        catch { done("保存失败：\(error.localizedDescription)") }
                    }
                }
            }
        }
    }
}
