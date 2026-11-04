import AppKit

enum VocabularyError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

final class VocabularyStore {
    static let limit = 200
    let file: URL
    init(directory: URL) { file = directory.appendingPathComponent("dictionary.json") }

    static func validate(_ lines: [String]) throws -> [String] {
        var terms: [String] = [], seen = Set<String>()
        for line in lines {
            let term = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if term.isEmpty { continue }
            guard term.count <= 64, !term.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw VocabularyError.invalid("每个词最多64个字，不能包含制表符或换行。")
            }
            if seen.insert(term.lowercased()).inserted { terms.append(term) }
        }
        guard terms.count <= limit else { throw VocabularyError.invalid("词库最多保留200个词，请优先填写常用专名和术语。") }
        return terms
    }
    func load() throws -> [String] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try Self.validate(JSONDecoder().decode([String].self, from: Data(contentsOf: file)))
    }
    @discardableResult func save(_ text: String) throws -> [String] {
        let terms = try Self.validate(text.components(separatedBy: .newlines))
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        try encoder.encode(terms).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return terms
    }
}

final class VocabularyWindow: NSObject {
    let store: VocabularyStore, window: NSWindow
    let text = NSTextView(), info = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton()
    init(store: VocabularyStore) {
        self.store = store
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 440), styleMask: [.titled,.closable,.resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "freetalk · 个人词库"; window.isReleasedWhenClosed = false; window.center()
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14; stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20), stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20), stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -20)])
        let help = NSTextField(wrappingLabelWithString: "每行一个词，填写你希望输出的拼写，例如 SFT、DeepSeek 或人名。\n保存后从下一次录音生效，仅保存在本机。")
        stack.addArrangedSubview(help)
        text.isRichText = false; text.isAutomaticQuoteSubstitutionEnabled = false; text.isAutomaticDashSubstitutionEnabled = false; text.isAutomaticSpellingCorrectionEnabled = false
        text.font = .systemFont(ofSize: 15); text.isVerticallyResizable = true; text.isHorizontallyResizable = false; text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true; text.textContainerInset = NSSize(width: 10, height: 10); text.setAccessibilityLabel("个人词库，每行一个词")
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; scroll.documentView = text
        stack.addArrangedSubview(scroll); scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true; scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        saveButton.title = "保存词库"; saveButton.bezelStyle = .rounded; saveButton.target = self; saveButton.action = #selector(save)
        stack.addArrangedSubview(saveButton)
        info.font = .systemFont(ofSize: 12); info.textColor = .secondaryLabelColor; stack.addArrangedSubview(info)
    }
    func show() {
        if !window.isVisible {
            do { let terms = try store.load(); text.string = terms.joined(separator: "\n"); info.stringValue = "\(terms.count) / 200 个词 · 可修改或删除行后保存"; saveButton.isEnabled = true }
            catch { info.stringValue = "词库读取失败，原文件已保留：\(error.localizedDescription)"; saveButton.isEnabled = false }
        }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func save() {
        do {
            let terms = try store.save(text.string); text.string = terms.joined(separator: "\n")
            info.stringValue = "已保存 \(terms.count) / 200 个词 · 下一次录音生效"
        } catch { info.stringValue = "未保存：\(error.localizedDescription)" }
    }
}
