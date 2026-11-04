import Foundation
@main struct CorrectionsTests {
    static func expect(_ condition: Bool) { precondition(condition) }
    static func main() throws {
        let pair = CorrectionExtractor.propose(before:"请打开星禾知识库查一下。",after:"请打开星河知识库查一下。",terms:["星河","星河知识库"])
        precondition(pair?.0 == "星禾知识库" && pair?.1 == "星河知识库")
        let english = CorrectionExtractor.propose(before:"先跑 SFY 模型。",after:"先跑 SFT 模型。",terms:["SFT"])
        precondition(english?.0 == "SFY" && english?.1 == "SFT")
        for (a,b) in [("保留12个","保留13个"),("先用十个","先用十二个"),("可以发布","不可以发布"),("不要发布","要发布"),("删除这一整句。",""),("保持一样","保持一样")] { precondition(CorrectionExtractor.propose(before:a,after:b,terms:[]) == nil) }
        for (a,b) in [("开源。","开源？"),("先打开文件。","先关闭文件。"),("hello world","hello  world")] { precondition(CorrectionExtractor.propose(before:a,after:b,terms:[]) == nil) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("voice-correction-tests-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        let vocabulary = VocabularyStore(directory:dir); try vocabulary.save("SFT\n星河知识库")
        let store = CorrectionStore(directory:dir,vocabulary:vocabulary)
        try store.suggest(pair!.0,pair!.1); try store.suggest(pair!.0,pair!.1)
        let pending = try store.pending(), before = try store.aliases()
        precondition(pending.count == 1 && before.isEmpty)
        try store.accept(heard:pair!.0,term:pair!.1,id:pending[0].id)
        let after = try store.aliases(), cleared = try store.pending()
        precondition(after.count == 1 && after[0].heard == "星禾知识库" && cleared.isEmpty)
        let terms = try vocabulary.load(); precondition(terms == ["SFT","星河知识库"])
        let learned=try store.learn(heard:"Grook",term:"Groq")!
        expect((try store.aliases()).contains { $0.heard == "Grook" && $0.term == "Groq" })
        expect((try vocabulary.load()).contains("Groq"))
        expect(try store.undo(learned))
        expect(!(try store.aliases()).contains { $0.heard == "Grook" })
        expect(!(try vocabulary.load()).contains("Groq"))
        let update=try store.learn(heard:"星禾知识库",term:"星河")!
        expect(try store.undo(update))
        expect((try store.aliases()).first { $0.heard == "星禾知识库" }?.term == "星河知识库")
        let attrs = try FileManager.default.attributesOfItem(atPath:dir.appendingPathComponent("dictionary-aliases.json").path)
        precondition((attrs[.posixPermissions] as! NSNumber).intValue == 0o600)
        let devices = MicDevices.all(), current = MicDevices.selected(uid:nil,devices:devices)
        precondition(current == nil || current!.id == MicDevices.defaultInputID())
        precondition(MicDevices.selected(uid:"missing-test-device",devices:devices) == nil)
        print("Correction extraction, punctuation/meaning/number guards, automatic learning, scoped undo, 0600, device resolution passed")
        print("Current system input:",current?.name ?? "none")
    }
}
