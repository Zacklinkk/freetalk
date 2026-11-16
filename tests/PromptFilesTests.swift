import Foundation

@main struct PromptFilesTests {
    static func main() throws {
        let edits = FileManager.default.temporaryDirectory.appendingPathComponent("freetalk prompts " + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: edits) }
        let files = PromptFiles(builtinDirectory: URL(fileURLWithPath: "prompts", isDirectory: true), editedDirectory: edits)
        // Every listed prompt ships, and the shipped examples pass the same check the editor applies.
        for entry in PromptFiles.editable {
            guard let text = files.builtin(entry.file) else { preconditionFailure("missing built-in \(entry.file)") }
            precondition(PromptFiles.usable(text, file: entry.file), entry.file)
        }
        // Saving the built-in text keeps using the built-in file; a real edit is private and wins.
        try files.save(files.builtin("edit-rules.txt")!, as: "edit-rules.txt")
        precondition(files.edited("edit-rules.txt") == nil)
        try files.save("只删口水词。\n", as: "edit-rules.txt")
        precondition(files.edited("edit-rules.txt") == "只删口水词。\n")
        let mode = { (path: String) in ((try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber)?.intValue }
        precondition(mode(edits.path) == 0o700 && mode(edits.appendingPathComponent("edit-rules.txt").path) == 0o600)
        try files.reset("edit-rules.txt"); try files.reset("edit-rules.txt")
        precondition(files.edited("edit-rules.txt") == nil)
        // Unusable edits are refused before anything is written.
        let pair = "[{\"role\":\"user\",\"content\":\"句子\"},{\"role\":\"assistant\",\"content\":\"{}\"}]"
        precondition(PromptFiles.usable(pair, file: "edit-plan-examples.json") && PromptFiles.usable("[]", file: "edit-plan-examples.json"))
        for bad in ["{broken", "{}", "[1,2]", "[{\"role\":\"user\",\"content\":\"x\"}]",
                    "[{\"role\":\"assistant\",\"content\":\"x\"},{\"role\":\"user\",\"content\":\"y\"}]",
                    "[{\"role\":\"user\",\"content\":\"x\",\"name\":\"n\"},{\"role\":\"assistant\",\"content\":\"y\"}]",
                    "[{\"role\":\"user\",\"content\":1},{\"role\":\"assistant\",\"content\":\"y\"}]"] {
            precondition(!PromptFiles.usable(bad, file: "edit-plan-examples.json"), bad)
            precondition((try? files.save(bad, as: "edit-plan-examples.json")) == nil)
        }
        precondition(files.edited("edit-plan-examples.json") == nil)
        precondition(!PromptFiles.usable(" \n", file: "edit-plan.txt") && PromptFiles.usable("{不是 JSON 也可以}", file: "edit-plan.txt"))
        // Before an adopted rewrite replaces an edited copy, the copy is backed up; only the newest 10 stay.
        let none = try files.backup("edit-rules.txt")
        precondition(none == nil)
        for i in 0..<12 {
            try files.save("第 \(i) 版规则。\n", as: "edit-rules.txt")
            let copy = try files.backup("edit-rules.txt", now: Date(timeIntervalSince1970: 1_800_000_000 + Double(i)))
            precondition(copy.flatMap { try? String(contentsOf: $0, encoding: .utf8) } == "第 \(i) 版规则。\n")
            precondition(copy.map { mode($0.path) } == 0o600)
        }
        let kept = try FileManager.default.contentsOfDirectory(atPath: edits.appendingPathComponent("backups").path).sorted()
        precondition(kept.count == 10 && kept.first?.hasPrefix("edit-rules-") == true, "\(kept)")
        print("Prompt files passed: all built-ins usable, built-in text not copied, private edits win, reset, unusable edits refused, backups before a rewrite")
    }
}
