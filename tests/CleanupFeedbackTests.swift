import Foundation

@main struct CleanupFeedbackTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("freetalk feedback " + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CleanupFeedbackStore(directory: root)
        // A cleanup change the user reverted is recorded, privately.
        precondition(store.record(raw: "嗯，我们先测试一下这个接口。", inserted: "我们先测试接口。", final: "我们先测试一下这个接口。"))
        precondition(store.load().count == 1)
        let mode = (try FileManager.default.attributesOfItem(atPath: store.file.path)[.posixPermissions] as? NSNumber)?.intValue
        precondition(mode == 0o600)
        // Cleanup changed nothing but the user still fixed it (a missed filler): kept.
        precondition(store.record(raw: "然后就是先跑测试。", inserted: "然后就是先跑测试。", final: "先跑测试。"))
        // Untouched, emptied, or only appended to: not about cleanup.
        precondition(!store.record(raw: "保存文件。", inserted: "保存文件。", final: "保存文件。"))
        precondition(!store.record(raw: "保存文件。", inserted: "保存文件。", final: ""))
        precondition(!store.record(raw: "保存文件。", inserted: "保存文件。", final: "保存文件。另外把日志也发我。"))
        // Invisible characters a web editor adds are not an edit.
        precondition(!store.record(raw: "保存文件。", inserted: "保存文件。", final: "保存文件。\u{200B}\n"))
        // The same dictation edited again replaces its earlier record; newest first.
        precondition(store.record(raw: "嗯，我们先测试一下这个接口。", inserted: "我们先测试接口。", final: "我们先测一下这个接口。"))
        let rows = store.load()
        precondition(rows.count == 2 && rows[0].final == "我们先测一下这个接口。")
        for i in 0..<70 { store.record(raw: "第\(i)条原稿", inserted: "第\(i)稿", final: "第\(i)条原稿") }
        precondition(store.load().count == CleanupFeedbackStore.limit)
        store.clear(); precondition(store.load().isEmpty)
        // Preferences round-trip and fail closed.
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        precondition(CleanupPreferences.load(root).isEmpty)
        try CleanupPreferences.save(["保留句末语气词。"], model: "strong", support: root)
        precondition(CleanupPreferences.load(root) == ["保留句末语气词。"])
        try Data("{broken".utf8).write(to: CleanupPreferences.file(root))
        precondition(CleanupPreferences.load(root).isEmpty)
        print("Cleanup feedback passed: recorded only cleanup-relevant edits, 0600, dedupe, 60-row cap, clear, preferences round-trip")
    }
}
