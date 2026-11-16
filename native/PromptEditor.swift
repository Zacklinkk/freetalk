import AppKit

/// Settings card: read and edit the prompts the cleanup model receives.
final class PromptEditorPanel: NSObject {
    unowned let app: AppDelegate
    private lazy var files = PromptFiles(builtinDirectory: Bundle.main.resourceURL?.appendingPathComponent("prompts", isDirectory: true),
                                         editedDirectory: app.support.appendingPathComponent("prompts", isDirectory: true))
    private let picker = NSPopUpButton()
    private let scroll = NSTextView.scrollableTextView()
    private var editor: NSTextView { scroll.documentView as! NSTextView }
    private let note = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    /// The text as last loaded or saved, to notice unsaved changes.
    private var loaded = ""
    private var index = 0
    private var saveButton: NSButton!, keepButton: NSButton!
    /// The eval set is running with the edit; dictation waits until it finishes.
    private(set) var checking = false
    /// An edit that made the eval set worse, kept so the user can still save it.
    private var refused: (file: String, text: String)?
    init(app: AppDelegate) { self.app = app; super.init() }

    func makeCard() -> NSView {
        picker.addItems(withTitles: PromptFiles.editable.map(\.title))
        picker.target = self; picker.action = #selector(choose); picker.setAccessibilityLabel("选择提示词")
        editor.isRichText = false; editor.allowsUndo = true; editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        // Smart quotes and dashes would silently corrupt the JSON examples.
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false; editor.isAutomaticSpellingCorrectionEnabled = false
        editor.textContainerInset = NSSize(width: 8, height: 8); editor.setAccessibilityLabel("提示词内容")
        scroll.borderType = .bezelBorder; scroll.heightAnchor.constraint(equalToConstant: 280).isActive = true
        for field in [note, status] { field.font = .systemFont(ofSize: 12); field.textColor = .secondaryLabelColor }
        saveButton = app.button("检查并保存", #selector(saveEdit)); saveButton.target = self
        keepButton = app.button("仍然保存", #selector(keepEdit)); keepButton.target = self; keepButton.isHidden = true
        let revert = app.button("放弃修改", #selector(revertEdit)); revert.target = self
        let reset = app.button("恢复默认", #selector(resetEdit)); reset.target = self
        load(0)
        let card = app.card("整理提示词", "整理模型收到的提示词原文。保存前先用内置测试集在本机比较修改前后的整理结果，没有变差才保存；修改只保存在本机，可随时恢复默认。无法使用的修改（例如示例不是合法 JSON）会被忽略，改用默认提示词。", views: [
            VoiceAppearance.form([("提示词", picker)]), note, scroll, app.row([saveButton, keepButton, revert, reset]), status])
        if let container = scroll.superview { scroll.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true }
        return card
    }

    private var file: String { PromptFiles.editable[index].file }

    private func load(_ position: Int) {
        index = position; picker.selectItem(at: position)
        refused = nil; keepButton?.isHidden = true
        let edited = files.edited(file)
        let text = edited ?? files.builtin(file) ?? ""
        editor.string = text; loaded = text
        note.stringValue = PromptFiles.editable[position].note
        if let edited = edited, !PromptFiles.usable(edited, file: file) {
            status.stringValue = "这份修改无法使用，口述时用的是默认内容：\(invalidReason(edited))"
        } else {
            status.stringValue = (edited == nil ? "默认内容" : "已修改，保存在本机") + " · \(text.count) 字"
        }
    }

    private func invalidReason(_ text: String) -> String {
        do { try PromptFiles.validate(text, file: file); return "" } catch { return error.localizedDescription }
    }

    @objc private func choose() {
        let next = picker.indexOfSelectedItem
        guard next != index else { return }
        if editor.string != loaded {
            let alert = NSAlert()
            alert.messageText = "放弃对「\(PromptFiles.editable[index].title)」未保存的修改？"
            alert.addButton(withTitle: "放弃修改"); alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { picker.selectItem(at: index); return }
        }
        load(next)
    }

    /// Saving rebuilds the worker's prompt caches, which must not race a dictation.
    private var idle: Bool { app.phase == .idle && !app.promptTuning.busy && !app.meetings.busy && !checking }

    /// Run the eval set with the saved prompts and with this edit; save only if
    /// no case that matched before stops matching.
    @objc private func saveEdit() {
        guard idle else { status.stringValue = "正在口述或处理，结束后再保存。"; return }
        let text = editor.string, name = file
        do { try PromptFiles.validate(text, file: name) } catch { status.stringValue = error.localizedDescription; return }
        if text == (files.builtin(name) ?? "") || !app.worker.ready || !PromptFiles.cleanup.contains(name) { store(text, as: name); return }
        checking = true; saveButton.isEnabled = false; keepButton.isHidden = true
        status.stringValue = "正在用测试集检查修改（约需几分钟，期间暂停口述）…"
        app.worker.onTuneProgress = { [weak self] event in
            guard let self = self, let done = event["completed"] as? Int, let total = event["total"] as? Int else { return }
            self.status.stringValue = (event["stage"] as? String == "eval-before" ? "正在用当前提示词跑测试集" : "正在用修改后的提示词跑测试集") + " \(done)/\(total)…"
        }
        app.worker.request("prompt_check", ["name": name, "text": text]) { [weak self] response in
            guard let self = self else { return }
            self.app.worker.onTuneProgress = nil; self.checking = false; self.saveButton.isEnabled = true
            switch response {
            case .failure(let error): self.status.stringValue = "检查未完成：\(error.localizedDescription)"
            case .success(let value):
                let before = value["before"] as? Int ?? 0, after = value["after"] as? Int ?? 0, total = value["total"] as? Int ?? 0
                let lost = value["regressions"] as? [String] ?? []
                if value["worse"] as? Bool == true {
                    self.refused = (name, text); self.keepButton.isHidden = false
                    self.status.stringValue = "未保存：测试集 \(before) → \(after) / \(total) 条通过" + (lost.isEmpty ? "。" : "，变差的是 \(lost.joined(separator: "、"))。") + "确定要用可以点“仍然保存”。"
                } else {
                    self.store(text, as: name, note: "测试集 \(before) → \(after) / \(total) 条通过")
                }
            }
        }
    }

    @objc private func keepEdit() {
        guard let refused = refused, refused.file == file, idle else { return }
        store(refused.text, as: refused.file, note: "测试集结果变差，按你的选择保存")
    }

    private func store(_ text: String, as name: String, note: String? = nil) {
        do {
            try files.save(text, as: name)
            if name == file { loaded = text }
            refused = nil; keepButton.isHidden = true
            apply((files.edited(name) == nil ? "与默认内容相同，已用回默认" : "已保存") + (note.map { "（\($0)）" } ?? ""))
        } catch { status.stringValue = error.localizedDescription }
    }

    @objc private func revertEdit() { load(index) }

    @objc private func resetEdit() {
        guard idle else { status.stringValue = "正在口述或处理，结束后再恢复默认。"; return }
        do { try files.reset(file); load(index); apply("已恢复默认") }
        catch { status.stringValue = "恢复失败：\(error.localizedDescription)" }
    }

    /// Ask the worker to reread the prompt files; it reads them at startup otherwise.
    private func apply(_ done: String) {
        let count = " · \(editor.string.count) 字"
        guard app.worker.ready else { status.stringValue = "\(done)\(count)。本地模型加载后生效。"; return }
        status.stringValue = "\(done)\(count)，正在应用…"
        app.worker.request("reload_prompts") { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success: self.status.stringValue = "\(done)\(count)，下次口述生效。"
            case .failure(let error): self.status.stringValue = "\(done)\(count)，但应用失败：\(error.localizedDescription)。重新加载模型后生效。"
            }
        }
    }
}
