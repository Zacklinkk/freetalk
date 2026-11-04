import Foundation
@main struct HistoryTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("freetalk-history-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{\"text\":\"旧记录\",\"raw\":\"呃，旧记录\",\"savedAt\":\"2026-11-01T08:00:00Z\"}".utf8).write(to: directory.appendingPathComponent("last-result.json"))
        let store = VoiceHistoryStore(directory: directory)
        precondition(store.entries.count == 1 && store.entries[0].text == "旧记录")
        for i in 0..<505 {
            store.upsert(VoiceHistoryEntry(id: String(i), createdAt: Date(), text: "文本\(i)", raw: "原稿\(i)", targetApp: "测试", insertionStatus: "待输入", audioSeconds: 40, stopToTextSeconds: 1, cleanupSeconds: 0.8, cleanupStatus: "小模型整理", modelUsed: true))
        }
        precondition(store.entries.count == 500 && store.entries.first?.id == "504" && store.entries.last?.id == "5")
        var latest = store.entries[0]; latest.insertionStatus = "已插入"
        latest.cleanupRoute="dictation_review"; latest.appliedEdits=2; latest.rejectedEdits=1; store.upsert(latest)
        precondition(store.entries.count == 500)
        let reloaded = VoiceHistoryStore(directory: directory)
        precondition(reloaded.entries.first?.insertionStatus == "已插入" && reloaded.entries.last?.id == "5")
        precondition(reloaded.entries.first?.cleanupRoute == "dictation_review" && reloaded.entries.first?.appliedEdits == 2 && reloaded.entries.first?.rejectedEdits == 1)
        precondition(reloaded.entries.last?.cleanupRoute == nil && reloaded.entries.last?.appliedEdits == nil)
        let permissions = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("history.json").path)[.posixPermissions] as! NSNumber
        precondition(permissions.intValue == 0o600)
        let corrupt = Data("do not overwrite corrupt history".utf8)
        try corrupt.write(to: directory.appendingPathComponent("history.json"))
        let bad = VoiceHistoryStore(directory: directory); bad.upsert(latest)
        let preserved = try Data(contentsOf: directory.appendingPathComponent("history.json"))
        precondition(bad.error != nil && preserved == corrupt)
        print("History passed: legacy migration, 505 -> newest 500, update without duplication, reload, 0600, corrupt file preserved")
    }
}
