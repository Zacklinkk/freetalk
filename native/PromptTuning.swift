import AppKit

/// Settings card: send collected cases to the strong cloud model, replay old
/// and new rules on this Mac with the user's cases and the eval set, and adopt
/// the new rules when neither got worse. Also runs once a night when enabled.
final class PromptTuningPanel: NSObject {
    unowned let app: AppDelegate
    let store: CleanupFeedbackStore
    private let summary = NSTextField(wrappingLabelWithString: "")
    private let result = NSTextField(wrappingLabelWithString: "")
    private let rules = NSTextField(wrappingLabelWithString: "")
    private var run: NSButton!, adopt: NSButton!, discard: NSButton!, reset: NSButton!, clear: NSButton!
    private var proposal: [String] = []
    /// A rewritten rule text with the preferences merged in, waiting for the user.
    private var rewrite: String?
    private var pending: Bool { !proposal.isEmpty || rewrite != nil }
    private var nightlyTimer: Timer?
    /// The worker is replaying cases; dictation waits until it finishes.
    private(set) var busy = false
    /// Waiting for the Keychain before a run starts; dictation is not blocked.
    private var reading = false
    init(app: AppDelegate) { self.app = app; store = CleanupFeedbackStore(directory: app.support); super.init() }

    func makeCard() -> NSView {
        for field in [summary, result, rules] { field.font = .systemFont(ofSize: 12); field.textColor = .secondaryLabelColor }
        rules.textColor = .labelColor
        run = app.button("用强模型优化整理规则", #selector(start)); run.target = self
        adopt = app.button("仍然采用", #selector(adoptRules)); adopt.target = self
        discard = app.button("放弃", #selector(discardRules)); discard.target = self
        reset = app.button("恢复默认规则", #selector(resetRules)); reset.target = self
        clear = app.button("清除记录", #selector(clearCases)); clear.target = self
        refresh()
        return app.card("整理规则优化", "口述插入后你又改动的文字会记在本机。积累一些后，可以请强模型总结成几条整理偏好；本机先用新旧规则重跑这些记录和内置测试集，都没有变差就自动采用，否则把结果给你看，由你决定。", views: [
            summary, app.row([run, clear]), result, rules, app.row([adopt, discard, reset]),
            app.label("会发送到云端：这些记录的原稿、整理结果和你改后的文字，以及现有整理规则。使用「语音输入 → 专业配置 → 云端模型」里的强模型；不发送音频和窗口文字。", size: 11, color: .secondaryLabelColor)])
    }

    func refresh() {
        // Called by the learner and the sidebar too; the buttons exist only once the card is built.
        guard run != nil, adopt != nil, discard != nil, reset != nil, clear != nil else { return }
        let count = store.load().count, active = CleanupPreferences.load(app.support)
        let night = UserDefaults.standard.string(forKey: "nightlyTuningReport").map { "\n夜间优化：\($0)" } ?? ""
        summary.stringValue = "已记录 \(count) 条插入后又被你改动的口述" + (active.isEmpty ? "，当前使用默认规则。" : "，当前使用 \(active.count) 条整理偏好：\n" + active.map { "· " + $0 }.joined(separator: "\n")) + night
        let cloud = CloudEditorSettings.load()
        let ready = cloud.serviceReady && cloud.tuning
        run.isEnabled = !busy && !reading && count >= 3 && ready && app.worker.ready && app.phase == .idle && !app.meetings.busy && !pending
        if !busy && !reading && !pending {
            if count < 3 { result.stringValue = "至少需要 3 条记录。" }
            else if !cloud.serviceReady { result.stringValue = "需要先在「语音输入 → 专业配置 → 云端模型」里填好服务、模型和密钥。" }
            else if !cloud.tuning { result.stringValue = "「云端模型」里没有勾选“整理规则优化”。" }
            else if result.stringValue.hasPrefix("至少") || result.stringValue.hasPrefix("需要先") || result.stringValue.hasPrefix("「云端模型」") { result.stringValue = "" }
        }
        adopt.isHidden = !pending; discard.isHidden = !pending; rules.isHidden = !pending
        reset.isHidden = active.isEmpty || pending
        clear.isEnabled = count > 0 && !busy
    }

    @objc private func start() {
        let cloud = CloudEditorSettings.load()
        guard cloud.serviceReady, cloud.tuning else { result.stringValue = "云端模型配置不完整，或没有勾选“整理规则优化”。"; return }
        // Nothing may have read the key at launch; wait for it here.
        // Dictation stays available while macOS shows the Keychain prompt.
        reading = true; refresh(); result.stringValue = "正在读取钥匙串中的密钥…（如果 macOS 询问，请选择“始终允许”）"
        CloudCredentialStore.prefetch(cloud.baseURL) { [weak self] credentials in
            guard let self = self else { return }
            self.reading = false
            guard let credentials = credentials else {
                self.result.stringValue = "无法从钥匙串读取 API Key：请在「云端模型」里重新保存，或在系统询问时选择“始终允许”。"
                self.refresh(); return
            }
            guard self.idle else { self.result.stringValue = "正在口述或处理会议，空闲后再试。"; self.refresh(); return }
            self.tune(cloud.payload(with: credentials, strong: true), model: cloud.strongName, automatic: false)
        }
    }

    private var idle: Bool {
        app.worker.ready && app.phase == .idle && !app.meetings.busy && !app.inserter.busy && !app.modelSetup.busy
            && !app.appUpdater.installing && !app.promptEditor.checking && !busy && !reading && !pending
    }

    private func tune(_ payload: [String: Any], model: String, automatic: Bool) {
        let cases = store.load().map { ["raw": $0.raw, "inserted": $0.inserted, "final": $0.final] }
        // Recent dictations the user left alone: the new rules must not disturb them.
        let edited = Set(store.load().map(\.raw))
        let accepted = app.historyStore.entries.filter { $0.modelUsed && !edited.contains($0.raw) && $0.insertionStatus.hasPrefix("已插入") }.prefix(10).map(\.raw)
        busy = true; run.isEnabled = false; result.stringValue = "正在请强模型总结…（随后本机重跑记录和测试集，约需几分钟，期间暂停口述）"
        app.worker.onTuneProgress = { [weak self] event in
            guard let self = self, let done = event["completed"] as? Int, let total = event["total"] as? Int else { return }
            switch event["stage"] as? String {
            case "rewrite": self.result.stringValue = "整理偏好已有 8 条以上，正在请强模型把它们并入整理规则…"
            case "replay": self.result.stringValue = "正在本机用新旧规则重跑记录 \(done)/\(total)…"
            case "eval-before": self.result.stringValue = "正在用现有规则跑测试集 \(done)/\(total)…"
            case "eval-after": self.result.stringValue = "正在用新规则跑测试集 \(done)/\(total)…"
            default: break
            }
        }
        let terms = (try? app.vocabularyStore.load()) ?? []
        let policy = ["auto", "always", "fast"][max(0, min(2, app.cleanupPicker.indexOfSelectedItem))]
        app.worker.request("prompt_tune", ["cloud": payload, "cases": cases, "accepted": Array(accepted), "terms": terms, "policy": policy]) { [weak self] response in
            guard let self = self else { return }
            self.app.worker.onTuneProgress = nil; self.busy = false
            switch response {
            case .failure(let error):
                let reason = CloudEditorSettings.describe(fallback: error.localizedDescription)
                self.result.stringValue = "未完成：\(reason)"
                if automatic { self.report("未完成：\(reason)") }
            case .success(let value):
                let proposed = value["rules"] as? [String] ?? []
                let rewritten = value["prompt"] as? String
                let merged = value["merged"] as? [String] ?? []
                let reason = value["reason"] as? String ?? ""
                if proposed.isEmpty && rewritten == nil {
                    self.result.stringValue = "强模型没有找到可靠的共性问题，规则保持不变。"
                    if automatic { self.report("没有找到可靠的共性问题，规则不变") }
                } else if value["adopt"] as? Bool == true {
                    let done = rewritten == nil ? "已自动采用：\(reason)。下次口述生效。"
                        : "已把 \(merged.count) 条整理偏好并入整理规则：\(reason)。新规则可在「整理提示词」查看或恢复默认，下次口述生效。"
                    self.save(proposed, prompt: rewritten, model: model, message: done)
                    if automatic { self.report(rewritten == nil ? "已自动采用 \(proposed.count) 条整理偏好（\(reason)）" : "已把 \(merged.count) 条整理偏好并入整理规则（\(reason)）") }
                } else if automatic {
                    self.report("未采用：\(reason)")
                } else {
                    self.proposal = proposed; self.rewrite = rewritten
                    self.rules.stringValue = (rewritten == nil ? "建议的整理偏好：\n" + proposed.map { "· " + $0 }.joined(separator: "\n")
                        : "建议把这些整理偏好并入整理规则（采用后可在「整理提示词」查看全文）：\n" + merged.map { "· " + $0 }.joined(separator: "\n")) + Self.details(value)
                    self.result.stringValue = "未自动采用：\(reason)。可以查看下面的变化后决定。"
                }
            }
            self.refresh()
        }
    }

    /// What changed, for a proposal that was not adopted automatically.
    private static func details(_ value: [String: Any]) -> String {
        let scores = value["scores"] as? [String: Int] ?? [:]
        var lines = ["本机重跑：\(scores["improved"] ?? 0) 条更接近你改后的文字，\(scores["worse"] ?? 0) 条更远，\(scores["same"] ?? 0) 条不变。"]
        if let eval = value["eval"] as? [String: Any] {
            let lost = eval["regressions"] as? [String] ?? []
            lines.append("测试集：\(eval["before"] as? Int ?? 0) → \(eval["after"] as? Int ?? 0) / \(eval["total"] as? Int ?? 0) 条通过" + (lost.isEmpty ? "。" : "；变差：\(lost.joined(separator: "、"))。"))
        }
        let examples = (value["examples"] as? [[String: String]] ?? []).filter { $0["result"] != "improved" }.prefix(3)
        lines += examples.map { "· 原来：\($0["before"] ?? "")\n  新规则：\($0["after"] ?? "")" }
        return "\n\n" + lines.joined(separator: "\n")
    }

    /// Save adopted preferences, or a rewritten rule text with the preferences emptied.
    private func save(_ proposed: [String], prompt: String? = nil, model: String, message: String) {
        do {
            if let prompt = prompt { try app.promptEditor.adopt(prompt, as: "edit-rules.txt") }
            try CleanupPreferences.save(proposed, model: model, support: app.support)
            app.worker.request("set_preferences", ["rules": proposed])
            result.stringValue = message
        } catch { result.stringValue = "保存失败：\(error.localizedDescription)" }
    }

    private func report(_ text: String) {
        let formatter = DateFormatter(); formatter.dateFormat = "M月d日 HH:mm"
        UserDefaults.standard.set("\(formatter.string(from: Date()))，\(text)", forKey: "nightlyTuningReport")
    }

    // MARK: Nightly

    /// Check every ten minutes whether tonight's run is due.
    func scheduleNightly() {
        nightlyTimer?.invalidate()
        nightlyTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in self?.runNightlyIfDue() }
    }

    /// Once a night, between 00:30 and 06:00, when there are new cases and the
    /// Mac has been idle for 15 minutes. A Keychain prompt at night would wait
    /// for nobody, so a key that was never read this launch skips the night.
    func runNightlyIfDue(now: Date = Date()) {
        let cloud = CloudEditorSettings.load()
        guard cloud.nightly, cloud.serviceReady, idle else { return }
        let calendar = Calendar.current
        let minutes = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        guard (30..<360).contains(minutes) else { return }
        let defaults = UserDefaults.standard
        if let last = defaults.object(forKey: "nightlyTuningLastRun") as? Date, calendar.isDate(last, inSameDayAs: now) { return }
        if let recent = app.historyStore.entries.first?.createdAt, now.timeIntervalSince(recent) < 15 * 60 { return }
        let cases = store.load()
        guard cases.count >= 3, let newest = cases.map(\.createdAt).max() else { return }
        if let stamp = defaults.object(forKey: "nightlyTuningCasesStamp") as? Date, newest <= stamp { return }
        defaults.set(now, forKey: "nightlyTuningLastRun")
        guard let credentials = CloudCredentialStore.cached(cloud.baseURL) else {
            report("钥匙串尚未授权，今晚跳过；白天测试一次云端连接即可"); refresh(); return
        }
        defaults.set(newest, forKey: "nightlyTuningCasesStamp")
        tune(cloud.payload(with: credentials, strong: true), model: cloud.strongName, automatic: true)
    }

    @objc private func adoptRules() {
        save(proposal, prompt: rewrite, model: CloudEditorSettings.load().strongName, message: "已采用，下次口述生效。")
        proposal = []; rewrite = nil; rules.stringValue = ""; refresh()
    }
    @objc private func clearCases() { store.clear(); result.stringValue = "已清除本机记录。"; refresh() }
    @objc private func discardRules() { proposal = []; rewrite = nil; rules.stringValue = ""; result.stringValue = "已放弃，规则保持不变。"; refresh() }
    @objc private func resetRules() {
        try? FileManager.default.removeItem(at: CleanupPreferences.file(app.support))
        app.worker.request("set_preferences", ["rules": [String]()])
        result.stringValue = "已恢复默认规则。"; refresh()
    }
}
