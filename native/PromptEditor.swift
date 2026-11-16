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
        let save = app.button("保存", #selector(saveEdit)); save.target = self
        let revert = app.button("放弃修改", #selector(revertEdit)); revert.target = self
        let reset = app.button("恢复默认", #selector(resetEdit)); reset.target = self
        load(0)
        let card = app.card("整理提示词", "整理模型收到的提示词原文。修改只保存在本机，可随时恢复默认；无法使用的修改（例如示例不是合法 JSON）会被忽略，改用默认提示词。", views: [
            VoiceAppearance.form([("提示词", picker)]), note, scroll, app.row([save, revert, reset]), status])
        if let container = scroll.superview { scroll.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true }
        return card
    }

    private var file: String { PromptFiles.editable[index].file }

    private func load(_ position: Int) {
        index = position; picker.selectItem(at: position)
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
    private var idle: Bool { app.phase == .idle && !app.promptTuning.busy && !app.meetings.busy }

    @objc private func saveEdit() {
        guard idle else { status.stringValue = "正在口述或处理，结束后再保存。"; return }
        do {
            try files.save(editor.string, as: file)
            loaded = editor.string
            apply(files.edited(file) == nil ? "与默认内容相同，已用回默认" : "已保存")
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
