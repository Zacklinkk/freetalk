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
        // Chinese lessons need a vocabulary entry for the new word, the same pinyin
        // and at least half the characters unchanged. Same pinyin alone also
        // matches deliberate rewrites; the vocabulary entry is what tells them apart.
        for (a,b,terms) in [("这个权利归你。","这个权力归你。",[String]()),     // no vocabulary evidence
                            ("打开服装设置。","打开浮窗设置。",["浮窗"]),       // different pinyin
                            ("请王小明处理。","请汪晓明处理。",["汪晓明"])] {   // 2 of 3 characters changed
            precondition(CorrectionExtractor.propose(before:a,after:b,terms:terms) == nil, "\(a) → \(b)")
        }
        precondition(CorrectionExtractor.propose(before:"进入插画环节。",after:"进入插话环节。",terms:["插话"])! == ("插画","插话"))
        precondition(CorrectionExtractor.propose(before:"联系李明，他负责。",after:"联系黎明，他负责。",terms:["黎明"])! == ("李明","黎明"))
        // Attribution: a span the recognizer produced is an ASR lesson; one only
        // the editor wrote is a cleanup lesson.
        precondition(CorrectionAttribution.stage(heard:"星禾知识库",raw:"打开星禾知识库",inserted:"打开星禾知识库") == .asr)
        precondition(CorrectionAttribution.stage(heard:"上线",raw:"周三发布",inserted:"周三上线") == .cleanup)
        // Repetition reinforces; time decays; old files decode with defaults.
        let start = Date(timeIntervalSince1970:1_800_000_000)
        _ = try store.learn(heard:"插画",term:"插话",stage:.asr,now:start)
        let again = try store.learn(heard:"插画",term:"插话",stage:.asr,now:start.addingTimeInterval(86_400))!
        precondition(again.reinforced && again.alias.count == 2)
        expect(try store.undo(again))
        let restored = try store.aliases().first { $0.heard == "插画" }
        precondition(restored?.count == 1)
        let fresh = VocabularyAlias(heard:"a",term:"b",count:2,lastSeen:start)
        precondition(abs(fresh.weight(at:start) - 2) < 0.001 && abs(fresh.weight(at:start.addingTimeInterval(30*86_400)) - 1) < 0.001)
        let legacy = try JSONDecoder().decode(VocabularyAlias.self, from:Data(#"{"heard":"get","term":"git"}"#.utf8))
        precondition(legacy.stage == .asr && legacy.count == 1 && legacy.weight() == 1)
        let legacyDir = dir.appendingPathComponent("legacy"); try FileManager.default.createDirectory(at:legacyDir,withIntermediateDirectories:true)
        try Data(#"[{"heard":"get","term":"git"}]"#.utf8).write(to:legacyDir.appendingPathComponent("dictionary-aliases.json"))
        let migrated = try CorrectionStore(directory:legacyDir,vocabulary:VocabularyStore(directory:legacyDir)).aliases(now:start)
        precondition(migrated.count == 1 && migrated[0].lastSeen == start)
        precondition(migrated[0].weight(at:start.addingTimeInterval(90*86_400)) < 0.25)
        let attrs = try FileManager.default.attributesOfItem(atPath:dir.appendingPathComponent("dictionary-aliases.json").path)
        precondition((attrs[.posixPermissions] as! NSNumber).intValue == 0o600)
        let devices = MicDevices.all(), current = MicDevices.selected(uid:nil,devices:devices)
        precondition(current == nil || current!.id == MicDevices.defaultInputID())
        precondition(MicDevices.selected(uid:"missing-test-device",devices:devices) == nil)
        print("Correction extraction, punctuation/meaning/number guards, pinyin+shared-character gate, ASR/cleanup attribution, reinforcement and decay, automatic learning, scoped undo, 0600, device resolution passed")
        print("Current system input:",current?.name ?? "none")
    }
}
