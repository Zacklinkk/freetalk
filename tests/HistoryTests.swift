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
        // Learning reports land on the entry later and survive a reload; old entries say nothing.
        precondition(reloaded.entries.last?.learningSummary == nil)
        reloaded.update("504") { $0.learned = [] }
        precondition(reloaded.entries[0].learningSummary == "未学习：插入后没有改动")
        reloaded.update("504") { $0.learningStop = "90 秒内没有改字" }
        precondition(reloaded.entries[0].learningSummary == "未学习：90 秒内没有改字")
        reloaded.update("504") { $0.editedText = "文本504（改）" }
        precondition(reloaded.entries[0].learningSummary?.hasPrefix("未学习：改动不像改字") == true)
        reloaded.update("504") { $0.learned = ["已学会 麦克 → Mac（识别）", "已记入整理规则优化的样例"] }
        reloaded.update("no-such-entry") { $0.editedText = "x" }
        let learned = VoiceHistoryStore(directory: directory)
        precondition(learned.entries[0].editedText == "文本504（改）" && learned.entries[0].learningSummary == "已学会 麦克 → Mac（识别）；已记入整理规则优化的样例")
        precondition(learned.entries.count == 500 && !learned.entries.contains { $0.id == "no-such-entry" })
        var off = learned.entries[1]; off.learningStop = "自动学习已关闭"
        precondition(off.learningSummary == "未学习：自动学习已关闭")
        let suite = "freetalk-history-"+UUID().uuidString
        let defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        let larger = VoiceHistoryStore(directory:directory,defaults:defaults)
        larger.setCapacity(2000)
        precondition(VoiceHistoryStore(directory:directory,defaults:defaults).capacity == 2000 && larger.p95 == nil)
        for i in 1...20 {
            larger.update(String(505-i)) { $0.stopToInputSeconds=Double(i) }
        }
        precondition(larger.p95 == 19)
        let permissions = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("history.json").path)[.posixPermissions] as! NSNumber
        precondition(permissions.intValue == 0o600)
        let corrupt = Data("do not overwrite corrupt history".utf8)
        try corrupt.write(to: directory.appendingPathComponent("history.json"))
        let bad = VoiceHistoryStore(directory: directory); bad.upsert(latest)
        let preserved = try Data(contentsOf: directory.appendingPathComponent("history.json"))
        precondition(bad.error != nil && preserved == corrupt)
        print("History passed: legacy migration, 505 -> newest 500, update without duplication, reload, learning notes on saved entries, 0600, corrupt file preserved")
    }
}
