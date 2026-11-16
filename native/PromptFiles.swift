import Foundation

/// The prompts the cleanup model receives, and the user's edited copies.
/// Edits live in <support>/prompts and override the built-in files in the app
/// bundle. The worker reads the same files (python/prompt_files.py) and ignores
/// an edited copy it cannot use, so a bad edit falls back to the built-in prompt.
struct PromptFiles {
    static let editable: [(file: String, title: String, note: String)] = [
        ("edit-rules.txt", "整理规则", "口述整理和整句撤回共用的规则，插入两者的 {{edit-rules}} 处。"),
        ("edit-plan.txt", "口述整理", "每次需要整理时发给整理模型的系统提示词。"),
        ("edit-plan-examples.json", "口述整理示例", "跟在系统提示词后的示例对话：JSON 数组，用户（user）与助手（assistant）交替。"),
        ("restart-plan.txt", "整句撤回", "听到“算了，重新说”这类整句撤回时改用的系统提示词。"),
        ("restart-plan-examples.json", "整句撤回示例", "JSON 数组，用户（user）与助手（assistant）交替。"),
        ("filler-selection.txt", "口水词选择", "只需要判断口水词去留时使用的短提示词。"),
        ("prompt-tuning.txt", "规则优化", "「整理规则优化」发给云端模型的提示词。"),
        ("prompt-rewrite.txt", "规则重写", "整理偏好积累到 8 条时，请强模型把它们并入整理规则所用的提示词。"),
        ("translation.txt", "翻译输入", "翻译输入时发给翻译模型的系统提示词；目标语言随原文一起发送。"),
    ]

    /// Prompts the cleanup eval set can measure; the others are saved without it.
    static let cleanup: Set<String> = ["edit-rules.txt", "edit-plan.txt", "edit-plan-examples.json", "restart-plan.txt",
                                       "restart-plan-examples.json", "filler-selection.txt"]

    struct Invalid: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    let builtinDirectory: URL?
    let editedDirectory: URL

    func builtin(_ file: String) -> String? {
        builtinDirectory.flatMap { try? String(contentsOf: $0.appendingPathComponent(file), encoding: .utf8) }
    }

    func edited(_ file: String) -> String? {
        try? String(contentsOf: editedDirectory.appendingPathComponent(file), encoding: .utf8)
    }

    /// Whether the worker will use this edited copy instead of the built-in one.
    static func usable(_ text: String, file: String) -> Bool { (try? validate(text, file: file)) != nil }

    static func validate(_ text: String, file: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Invalid(message: "提示词不能为空；要用回默认内容请点「恢复默认」。")
        }
        guard file.hasSuffix(".json") else { return }
        guard let turns = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [[String: Any]] else {
            throw Invalid(message: "示例需要是 JSON 数组，每项形如 {\"role\":\"user\",\"content\":\"…\"}。")
        }
        guard turns.count % 2 == 0 else { throw Invalid(message: "示例要成对出现：每条用户（user）后面跟一条助手（assistant）。") }
        for (index, turn) in turns.enumerated() {
            guard Set(turn.keys) == ["role", "content"], turn["content"] is String,
                  turn["role"] as? String == (index % 2 == 0 ? "user" : "assistant") else {
                throw Invalid(message: "第 \(index + 1) 项需要只有 role 和 content，role 依次为 user、assistant。")
            }
        }
    }

    /// Save the user's copy. Saving the built-in text removes the copy instead.
    func save(_ text: String, as file: String) throws {
        try Self.validate(text, file: file)
        if text == builtin(file) { try reset(file); return }
        try FileManager.default.createDirectory(at: editedDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = editedDirectory.appendingPathComponent(file)
        try Data(text.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Copy the edited copy of `file`, if there is one, to backups/<name>-<time>.<ext>
    /// before something else replaces it. The newest 10 backups of a file are kept.
    @discardableResult func backup(_ file: String, now: Date = Date()) throws -> URL? {
        let source = editedDirectory.appendingPathComponent(file)
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        let folder = editedDirectory.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stem = (file as NSString).deletingPathExtension, ext = (file as NSString).pathExtension
        let target = folder.appendingPathComponent("\(stem)-\(formatter.string(from: now)).\(ext)")
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        try FileManager.default.copyItem(at: source, to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        let kept = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(stem + "-") }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in kept.dropFirst(10) { try? FileManager.default.removeItem(at: old) }
        return target
    }

    func reset(_ file: String) throws {
        let url = editedDirectory.appendingPathComponent(file)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
