import AppKit

/// Settings card: send collected cases to the cloud model, replay old and new
/// rules on this Mac, show both, and let the user adopt or discard.
final class PromptTuningPanel: NSObject {
    unowned let app: AppDelegate
    let store: CleanupFeedbackStore
    private let summary = NSTextField(wrappingLabelWithString: "")
    private let result = NSTextField(wrappingLabelWithString: "")
    private let rules = NSTextField(wrappingLabelWithString: "")
    private var run: NSButton!, adopt: NSButton!, discard: NSButton!, reset: NSButton!, clear: NSButton!
    private let model = NSTextField()
    private var proposal: [String] = []
    /// The worker is replaying cases; dictation waits until it finishes.
    private(set) var busy = false
    init(app: AppDelegate) { self.app = app; store = CleanupFeedbackStore(directory: app.support); super.init() }

    func makeCard() -> NSView {
        for field in [summary, result, rules] { field.font = .systemFont(ofSize: 12); field.textColor = .secondaryLabelColor }
        rules.textColor = .labelColor
        run = app.button("用云端模型优化整理规则", #selector(start)); run.target = self
        adopt = app.button("采用新规则", #selector(adoptRules)); adopt.target = self
        discard = app.button("放弃", #selector(discardRules)); discard.target = self
        reset = app.button("恢复默认规则", #selector(resetRules)); reset.target = self
        clear = app.button("清除记录", #selector(clearCases)); clear.target = self
        model.placeholderString = "可选 · 留空则用云端整理的模型；建议填同一服务里更强的模型"
        model.stringValue = UserDefaults.standard.string(forKey: "promptTuningModel") ?? ""
        model.setAccessibilityLabel("规则优化使用的模型")
        refresh()
        return app.card("整理规则优化", "口述插入后你又改动的文字会记在本机。积累一些后，可以请云端模型总结成几条整理偏好；本机先用新旧规则重跑这些记录，结果给你看，你确认后才生效。", views: [
            summary, VoiceAppearance.form([("优化用模型", model)]), app.row([run, clear]), result, rules, app.row([adopt, discard, reset]),
            app.label("会发送到云端：这些记录的原稿、整理结果和你改后的文字，以及现有整理规则。使用「云端整理」里填的服务与密钥；不发送音频和窗口文字。", size: 11, color: .secondaryLabelColor)])
    }

    func refresh() {
        // Called by the learner and the sidebar too; the buttons exist only once the card is built.
        guard run != nil, adopt != nil, discard != nil, reset != nil, clear != nil else { return }
        let count = store.load().count, active = CleanupPreferences.load(app.support)
        summary.stringValue = "已记录 \(count) 条插入后又被你改动的口述" + (active.isEmpty ? "，当前使用默认规则。" : "，当前使用 \(active.count) 条整理偏好：\n" + active.map { "· " + $0 }.joined(separator: "\n"))
        // Tuning needs the service and key, not cloud cleanup itself switched on.
        var cloud = CloudEditorSettings.load(); cloud.enabled = true
        let ready = cloud.configured
        run.isEnabled = !busy && count >= 3 && ready && app.worker.ready && app.phase == .idle && !app.meetings.busy && proposal.isEmpty
        if !busy && proposal.isEmpty {
            if count < 3 { result.stringValue = "至少需要 3 条记录。" }
            else if !ready { result.stringValue = "需要先在「语音输入 → 专业配置 → 云端整理」里填好服务和密钥（不必开启云端整理）。" }
        }
        adopt.isHidden = proposal.isEmpty; discard.isHidden = proposal.isEmpty; rules.isHidden = proposal.isEmpty
        reset.isHidden = active.isEmpty || !proposal.isEmpty
        clear.isEnabled = count > 0 && !busy
    }

    @objc private func start() {
        var cloud = CloudEditorSettings.load(); cloud.enabled = true
        guard var payload = cloud.payload() else { result.stringValue = "云端服务配置不完整。"; return }
        let strong = model.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(strong, forKey: "promptTuningModel")
        if !strong.isEmpty { payload["model"] = strong }
        let cases = store.load().map { ["raw": $0.raw, "inserted": $0.inserted, "final": $0.final] }
        // Recent dictations the user left alone: the new rules must not disturb them.
        let edited = Set(store.load().map(\.raw))
        let accepted = app.historyStore.entries.filter { $0.modelUsed && !edited.contains($0.raw) && $0.insertionStatus.hasPrefix("已插入") }.prefix(10).map(\.raw)
        busy = true; run.isEnabled = false; result.stringValue = "正在请云端模型总结…（随后本机重跑，约需几分钟，期间暂停口述）"
        app.worker.onTuneProgress = { [weak self] event in
            guard let self = self, event["stage"] as? String == "replay", let done = event["completed"] as? Int, let total = event["total"] as? Int else { return }
            self.result.stringValue = "正在本机用新旧规则重跑记录 \(done)/\(total)…"
        }
        let terms = (try? app.vocabularyStore.load()) ?? []
        let policy = ["auto", "always", "fast"][max(0, min(2, app.cleanupPicker.indexOfSelectedItem))]
        app.worker.request("prompt_tune", ["cloud": payload, "cases": cases, "accepted": Array(accepted), "terms": terms, "policy": policy]) { [weak self] response in
            guard let self = self else { return }
            self.app.worker.onTuneProgress = nil; self.busy = false
            switch response {
            case .failure(let error):
                self.result.stringValue = "未完成：\(CloudEditorSettings.describe(fallback: error.localizedDescription))"
            case .success(let value):
                let proposed = value["rules"] as? [String] ?? []
                let scores = value["scores"] as? [String: Int] ?? [:]
                if proposed.isEmpty { self.result.stringValue = "云端模型没有找到可靠的共性问题，规则保持不变。" }
                else {
                    self.proposal = proposed
                    let examples = value["examples"] as? [[String: String]] ?? []
                    let changed = examples.filter { $0["result"] == "accepted_changed" }.prefix(3)
                    self.rules.stringValue = "建议的整理偏好：\n" + proposed.map { "· " + $0 }.joined(separator: "\n") +
                        (changed.isEmpty ? "" : "\n\n会变化的口述（请确认没有变差）：\n" + changed.map { "· 原来：\($0["before"] ?? "")\n  新规则：\($0["after"] ?? "")" }.joined(separator: "\n"))
                    self.result.stringValue = "本机重跑 \(cases.count) 条记录：\(scores["improved"] ?? 0) 条更接近你改后的文字，\(scores["worse"] ?? 0) 条更远，\(scores["same"] ?? 0) 条不变。" +
                        ((scores["accepted_total"] ?? 0) > 0 ? "\n未发现改动的 \(scores["accepted_total"] ?? 0) 条近期口述中，有 \(scores["accepted_changed"] ?? 0) 条结果会变化。" : "")
                }
            }
            self.refresh()
        }
    }

    @objc private func adoptRules() {
        do {
            let used = model.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            try CleanupPreferences.save(proposal, model: used.isEmpty ? CloudEditorSettings.load().model : used, support: app.support)
            app.worker.request("set_preferences", ["rules": proposal])
            result.stringValue = "已采用，下次口述生效。"; proposal = []
        } catch { result.stringValue = "保存失败：\(error.localizedDescription)" }
        refresh()
    }
    @objc private func clearCases() { store.clear(); result.stringValue = "已清除本机记录。"; refresh() }
    @objc private func discardRules() { proposal = []; result.stringValue = "已放弃，规则保持不变。"; refresh() }
    @objc private func resetRules() {
        try? FileManager.default.removeItem(at: CleanupPreferences.file(app.support))
        app.worker.request("set_preferences", ["rules": [String]()])
        result.stringValue = "已恢复默认规则。"; refresh()
    }
}
