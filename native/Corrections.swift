import AppKit
import ApplicationServices
import Carbon
import NaturalLanguage

struct CorrectionSuggestion: Codable {
    var id: String, heard: String, term: String
    var createdAt: Date
}
/// Which stage produced the wrong word. The fix differs: an ASR mishearing
/// becomes a recognizer hint, a cleanup rewrite becomes an editor constraint.
enum CorrectionStage: String, Codable { case asr, cleanup }

/// A learned "heard → term" pattern. Older files only stored heard/term; the
/// rest decodes to neutral defaults so nothing is lost on upgrade.
struct VocabularyAlias: Codable, Equatable {
    var heard: String, term: String
    var stage: CorrectionStage = .asr
    var count: Int = 1
    var lastSeen: Date = .distantPast
    init(heard: String, term: String, stage: CorrectionStage = .asr, count: Int = 1, lastSeen: Date = .distantPast) {
        self.heard = heard; self.term = term; self.stage = stage; self.count = count; self.lastSeen = lastSeen
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        heard = try c.decode(String.self, forKey: .heard); term = try c.decode(String.self, forKey: .term)
        stage = (try? c.decode(CorrectionStage.self, forKey: .stage)) ?? .asr
        count = max(1, (try? c.decode(Int.self, forKey: .count)) ?? 1)
        lastSeen = (try? c.decode(Date.self, forKey: .lastSeen)) ?? .distantPast
    }
    /// Reinforcement decays: a pair confirmed once and never again fades out of
    /// the active set, so a single mistaken lesson cannot persist indefinitely.
    func weight(at now: Date = Date()) -> Double {
        // An unknown date (a pair saved before dates were recorded) counts as
        // fresh; CorrectionStore stamps it on first load so decay starts then.
        let days = lastSeen == .distantPast ? 0 : max(0, now.timeIntervalSince(lastSeen) / 86_400)
        return Double(count) * pow(0.5, days / 30)
    }
}

/// Where a correction came from in the pipeline, decided by comparing what the
/// recognizer heard (raw) with what cleanup produced (inserted).
enum CorrectionAttribution {
    /// `heard` is the span the user replaced in the inserted text. If it also
    /// appears verbatim in the raw transcript, the recognizer produced it; if it
    /// does not, cleanup introduced it.
    static func stage(heard: String, raw: String, inserted: String) -> CorrectionStage {
        if raw == inserted || raw.contains(heard) { return .asr }
        return .cleanup
    }
}
struct LearnedCorrection {
    let alias: VocabularyAlias
    let previous: VocabularyAlias?
    let addedTerm: Bool
    let wordsAfter: [String]
    /// True when this confirmed an existing pair rather than adding a new one.
    var reinforced: Bool { previous?.term == alias.term }
}

enum CorrectionExtractor {
    static func propose(before: String, after: String, terms: [String]) -> (String, String)? {
        let a = Array(before), b = Array(after)
        guard a != b, a.count <= 6000, b.count <= 6000 else { return nil }
        var left = 0, right = 0
        while left < min(a.count,b.count) && a[left] == b[left] { left += 1 }
        while right < min(a.count,b.count)-left && a[a.count-1-right] == b[b.count-1-right] { right += 1 }
        let oldEnd = a.count-right, newEnd = b.count-right
        guard oldEnd > left, newEnd > left, oldEnd-left <= 12, newEnd-left <= 12 else { return nil }
        let forbidden = ["不","无","非","没","要","能","可","应","not"]
        let changedOld = String(a[left..<oldEnd]), changedNew = String(b[left..<newEnd])
        // Punctuation/spacing changes are editing, not evidence of a misheard word.
        guard changedOld.contains(where: { $0.isLetter }), changedNew.contains(where: { $0.isLetter }) else { return nil }
        guard !forbidden.contains(where: { changedOld.contains($0) || changedNew.contains($0) }),
              !changedOld.contains(where: { $0.isNumber || "零〇一二两三四五六七八九十百千万亿".contains($0) }),
              !changedNew.contains(where: { $0.isNumber || "零〇一二两三四五六七八九十百千万亿".contains($0) }) else { return nil }
        func result(_ start: Int, _ end: Int) -> (String,String)? {
            let oldRight = end + a.count-b.count
            guard start <= left, end >= newEnd, oldRight >= oldEnd, oldRight <= a.count, start >= 0, end <= b.count else { return nil }
            let old = String(a[start..<oldRight]), new = String(b[start..<end])
            guard (2...24).contains(old.count), (2...24).contains(new.count), old != new,
                  !old.contains(where: { $0.isNewline }), !new.contains(where: { $0.isNewline }) else { return nil }
            func sound(_ text: String) -> String {
                (text.applyingTransform(.toLatin,reverse:false)?.applyingTransform(.stripDiacritics,reverse:false) ?? text).lowercased().filter { $0.isLetter }
            }
            let oldSound=sound(old), newSound=sound(new)
            func oneSoundEdit(_ x:String,_ y:String) -> Bool {
                let a=Array(x),b=Array(y)
                guard min(a.count,b.count)>=4 else { return false }
                if a.count==b.count { return zip(a,b).filter { $0 != $1 }.count == 1 }
                let small=a.count<b.count ? a : b, large=a.count<b.count ? b : a
                return large.count==small.count+1 && large.indices.contains { index in var candidate=large; candidate.remove(at:index); return candidate==small }
            }
            let latinTypo = old.allSatisfy { $0.isASCII && $0.isLetter } && new.allSatisfy { $0.isASCII && $0.isLetter } && old.count == new.count && zip(old.lowercased(),new.lowercased()).filter { $0 != $1 }.count == 1
            guard oldSound == newSound || oneSoundEdit(oldSound,newSound) || latinTypo else { return nil }
            // Sound-alike alone cannot tell a misheard word from a deliberate
            // rewording: 星禾→星河 (misheard) and 权利→权力 (reworded) are
            // acoustically identical. For Chinese, require the replacement to
            // already exist in the personal vocabulary — that is the only
            // evidence that the speaker meant this word and the recognizer got
            // it wrong. Latin typos (SFY→SFT) are unambiguous and stay direct.
            let isChinese = old.unicodeScalars.contains { $0.value > 0x4E00 && $0.value < 0x9FFF }
            if isChinese {
                guard terms.contains(where: { $0 == new || $0.hasPrefix(new) || new.hasPrefix($0) }) else { return nil }
                // A mishearing keeps the sound and most of the characters. Same
                // pinyin alone also matches deliberate rewrites (权利→权力).
                guard oldSound == newSound, old.count == new.count else { return nil }
                let shared = zip(old, new).filter { $0 == $1 }.count
                guard shared >= max(1, (old.count + 1) / 2) else { return nil }
            }
            return (old,new)
        }
        // Prefer an already known compound word instead of learning only a suffix.
        for term in terms.sorted(by: { $0.count > $1.count }) where term.count >= 2 {
            var search = after.startIndex..<after.endIndex
            while let range = after.range(of:term,range:search) {
                let start = after.distance(from:after.startIndex,to:range.lowerBound), end = after.distance(from:after.startIndex,to:range.upperBound)
                if start <= left && end >= newEnd, let item = result(start,end) { return item }
                search = range.upperBound..<after.endIndex
            }
        }
        let tokenizer = NLTokenizer(unit:.word); tokenizer.string = after
        let changedStart = after.index(after.startIndex,offsetBy:left), changedEnd = after.index(after.startIndex,offsetBy:newEnd)
        var start=left, end=newEnd
        tokenizer.enumerateTokens(in:after.startIndex..<after.endIndex) { range, _ in
            if range.lowerBound < changedEnd && range.upperBound > changedStart {
                start=min(start,after.distance(from:after.startIndex,to:range.lowerBound))
                end=max(end,after.distance(from:after.startIndex,to:range.upperBound))
            }
            return true
        }
        guard end-start <= 12 else { return nil }
        // A new single-character Chinese token is too ambiguous to learn automatically.
        return result(start,end)
    }
}

final class CorrectionStore {
    let directory: URL, vocabulary: VocabularyStore
    init(directory: URL, vocabulary: VocabularyStore) { self.directory = directory; self.vocabulary = vocabulary }
    func pending() throws -> [CorrectionSuggestion] {
        let file = directory.appendingPathComponent("correction-suggestions.json")
        guard FileManager.default.fileExists(atPath:file.path) else { return [] }
        return try JSONDecoder().decode([CorrectionSuggestion].self, from:Data(contentsOf:file)).filter {
            $0.heard.filter { $0.isLetter || $0.isNumber } != $0.term.filter { $0.isLetter || $0.isNumber }
        }
    }
    func aliases(now: Date = Date()) throws -> [VocabularyAlias] {
        let file = directory.appendingPathComponent("dictionary-aliases.json")
        guard FileManager.default.fileExists(atPath:file.path) else { return [] }
        var rows = try JSONDecoder().decode([VocabularyAlias].self,from:Data(contentsOf:file))
        // Pairs from before dates were recorded start their decay at upgrade time,
        // instead of being treated as a year old and silently dropped.
        if rows.contains(where: { $0.lastSeen == .distantPast }) {
            for index in rows.indices where rows[index].lastSeen == .distantPast { rows[index].lastSeen = now }
            try write(rows,to:"dictionary-aliases.json")
        }
        return rows
    }
    private func write<T: Encodable>(_ value: T, to name: String) throws {
        let file = directory.appendingPathComponent(name), encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try encoder.encode(value).write(to:file,options:.atomic); try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
    func suggest(_ heard: String, _ term: String) throws {
        var rows = try pending()
        guard !rows.contains(where: { $0.heard == heard && $0.term == term }), !(try aliases()).contains(where: { $0.heard == heard && $0.term == term }) else { return }
        rows.insert(CorrectionSuggestion(id:UUID().uuidString,heard:heard,term:term,createdAt:Date()),at:0)
        try write(Array(rows.prefix(100)),to:"correction-suggestions.json")
    }
    func dismiss(_ id: String) throws { try write(try pending().filter { $0.id != id },to:"correction-suggestions.json") }
    func removeAlias(_ heard: String) throws { try write(try aliases().filter { $0.heard != heard },to:"dictionary-aliases.json") }
    func accept(heard: String, term: String, id: String? = nil, stage: CorrectionStage = .asr, now: Date = Date()) throws {
        let old = heard.trimmingCharacters(in:.whitespacesAndNewlines), new = term.trimmingCharacters(in:.whitespacesAndNewlines)
        _ = try VocabularyStore.validate([old,new])
        guard old.count >= 2, new.count >= 2, old != new else { throw VocabularyError.invalid("请填写不同的识别词和正确词，每项至少2个字母或汉字。") }
        var words = try vocabulary.load(); if !words.contains(new) { words.append(new) }; try vocabulary.save(words.joined(separator:"\n"))
        var rows = try aliases()
        // Seeing the same correction again is evidence; count it instead of resetting.
        let same = rows.first { $0.heard == old && $0.term == new }
        rows.removeAll { $0.heard == old }
        rows.insert(VocabularyAlias(heard:old,term:new,stage:same?.stage ?? stage,count:(same?.count ?? 0) + 1,lastSeen:now),at:0)
        try write(Array(rows.prefix(200)),to:"dictionary-aliases.json")
        if let id = id { try dismiss(id) }
    }
    func learn(heard: String, term: String, stage: CorrectionStage = .asr, now: Date = Date()) throws -> LearnedCorrection? {
        let rows=try aliases(), words=try vocabulary.load(), previous=rows.first { $0.heard == heard }
        guard rows.count < 200 || previous != nil else { throw VocabularyError.invalid("纠正关系已满，请先在词库中整理。") }
        do { try accept(heard:heard,term:term,stage:stage,now:now) }
        catch { _ = try? vocabulary.save(words.joined(separator:"\n")); throw error }
        let stored = try aliases().first { $0.heard == heard } ?? VocabularyAlias(heard:heard,term:term,stage:stage)
        return LearnedCorrection(alias:stored,previous:previous,addedTerm:!words.contains(term),wordsAfter:try vocabulary.load())
    }
    @discardableResult func undo(_ change: LearnedCorrection) throws -> Bool {
        var rows=try aliases()
        guard rows.first(where: { $0.heard == change.alias.heard })?.term == change.alias.term else { return false }
        let original=rows
        rows.removeAll { $0.heard == change.alias.heard }
        // Undoing a reinforcement restores the earlier count rather than deleting the pair.
        if let previous=change.previous { rows.insert(previous,at:0) }
        try write(rows,to:"dictionary-aliases.json")
        do {
            let words=try vocabulary.load()
            if change.addedTerm && words == change.wordsAfter && !rows.contains(where: { $0.term == change.alias.term }) {
                try vocabulary.save(words.filter { $0 != change.alias.term }.joined(separator:"\n"))
            }
        } catch { try? write(original,to:"dictionary-aliases.json"); throw error }
        return true
    }
}

final class CorrectionLearner {
    private var timer: Timer?
    var onLearn: ((LearnedCorrection, CGRect?) -> Void)?
    var onError: ((String) -> Void)?
    func stop() { timer?.invalidate(); timer = nil }
    /// Why the most recent session ended, for the diagnostics line in Settings.
    private(set) var lastStop = ""
    var onStop: ((String) -> Void)?
    private func end(_ reason: String) { lastStop = reason; stop(); onStop?(reason) }
    func start(target: InputSnapshot, inserted: String, raw: String, store: CorrectionStore) {
        stop()
        // Web editors report the same text with different invisible characters
        // than they accepted (NBSP, zero-width space, CRLF); compare a normal form.
        func plain(_ text: String) -> String {
            text.replacingOccurrences(of:"\r\n",with:"\n").replacingOccurrences(of:"\u{00A0}",with:" ")
                .replacingOccurrences(of:"\u{200B}",with:"").replacingOccurrences(of:"\u{FEFF}",with:"")
        }
        let prefix = plain((target.value as NSString).substring(to:target.range.location))
        let suffix = plain((target.value as NSString).substring(from:target.range.location+target.range.length))
        let inserted = plain(inserted)
        var baseline = inserted, stableValue = "", stableSince = Date(), savedValue = ""
        var observedPairs = Set<String>()
        let began = Date()
        lastStop = ""
        timer = Timer.scheduledTimer(withTimeInterval:0.6,repeats:true) { [weak self] _ in
            guard let self = self else { return }
            if Date().timeIntervalSince(began) > 90 { self.end("90 秒内没有改字"); return }
            if IsSecureEventInputEnabled() { self.end("进入安全输入"); return }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else { self.end("切换到了其他应用"); return }
            guard let focused = focusedElement(target.pid),
                  !(axAttribute(focused,kAXSubroleAttribute) as? String ?? "").localizedCaseInsensitiveContains("secure") else { self.end("输入框失去焦点"); return }
            let same = CFEqual(focused,target.element) || (target.window != nil && axWindow(focused) != nil && CFEqual(target.window!,axWindow(focused)!) && target.identity.matchesReplacement(InputIdentity.read(focused)))
            guard same else { self.end("焦点移到了另一个输入框"); return }
            guard let read = axAttribute(focused,kAXValueAttribute) as? String, read.utf16.count <= 200_000 else { self.end("该应用不提供输入框文字"); return }
            let value = plain(read)
            // Sending a message empties the field: the session is over, not broken.
            guard value.hasPrefix(prefix), value.hasSuffix(suffix), value.count >= prefix.count+suffix.count else { self.end(value.isEmpty ? "内容已发送或清空" : "插入位置之外的文字被改动"); return }
            let edited = String(value.dropFirst(prefix.count).dropLast(suffix.count))
            if edited == baseline { return }
            if edited != stableValue { stableValue = edited; stableSince = Date(); return }
            guard Date().timeIntervalSince(stableSince) >= 1.5, savedValue != edited else { return }
            savedValue = edited
            if let pair = CorrectionExtractor.propose(before:baseline,after:edited,terms:(try? store.vocabulary.load()) ?? []) {
                let key=pair.0+"\u{0}"+pair.1
                if observedPairs.insert(key).inserted {
                    let stage = CorrectionAttribution.stage(heard:pair.0,raw:raw,inserted:inserted)
                    do { if let learned=try store.learn(heard:pair.0,term:pair.1,stage:stage) { self.onLearn?(learned,target.anchor) } }
                    catch { self.onError?(error.localizedDescription) }
                }
            }
            baseline=edited
        }
    }
    deinit { stop() }
}

final class CorrectionsWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let store: CorrectionStore, window: NSWindow
    let table = NSTableView(), heard = NSTextField(), term = NSTextField(), info = NSTextField(wrappingLabelWithString:"")
    let mode = NSSegmentedControl(labels:["待确认","已收录"],trackingMode:.selectOne,target:nil,action:nil)
    var rows: [CorrectionSuggestion] = []
    init(store: CorrectionStore) {
        self.store = store; window = NSWindow(contentRect:NSRect(x:0,y:0,width:680,height:470),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        super.init(); window.title = "freetalk · 已学会的纠正"; window.isReleasedWhenClosed = false; window.center()
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16; stack.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:22),stack.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-22),stack.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:22),stack.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor,constant:-22)])
        stack.addArrangedSubview(NSTextField(wrappingLabelWithString:"自动学会的纠正会用于下次录音，可在这里移除或手动补充。旧版建议仍可切到待确认页处理。"))
        mode.selectedSegment = 1; mode.target = self; mode.action = #selector(modeChanged); stack.addArrangedSubview(mode)
        for (key,title) in [("heard","识别成"),("term","改为")] { let col = NSTableColumn(identifier:NSUserInterfaceItemIdentifier(key)); col.title = title; col.width = 295; table.addTableColumn(col) }
        table.dataSource = self; table.delegate = self; table.rowHeight = 30; table.setAccessibilityLabel("改字建议列表")
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; stack.addArrangedSubview(scroll); scroll.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive = true; scroll.heightAnchor.constraint(equalToConstant:200).isActive = true
        heard.placeholderString = "识别成的词"; term.placeholderString = "正确的词"; heard.setAccessibilityLabel("识别成"); term.setAccessibilityLabel("应当是")
        let fields = NSStackView(views:[heard,term]); fields.spacing = 12; fields.distribution = .fillEqually; stack.addArrangedSubview(fields); fields.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive = true
        let accept = NSButton(title:"确认并加入词库",target:self,action:#selector(accept)), ignore = NSButton(title:"移除所选记录",target:self,action:#selector(ignore))
        accept.bezelStyle = .rounded; ignore.bezelStyle = .rounded; let actions = NSStackView(views:[accept,ignore]); actions.spacing = 12; stack.addArrangedSubview(actions)
        info.textColor = .secondaryLabelColor; info.font = .systemFont(ofSize:12); stack.addArrangedSubview(info)
    }
    func show() { refresh(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true) }
    func refresh() { do {
        rows = mode.selectedSegment == 0 ? try store.pending() : try store.aliases().map { CorrectionSuggestion(id:$0.heard,heard:$0.heard,term:$0.term,createdAt:Date()) }
        table.reloadData(); info.stringValue = "\(rows.count) 条\(mode.selectedSegment == 0 ? "待确认建议" : "纠正关系") · 仅在本机保存"
    } catch { info.stringValue = "读取失败，原文件已保留：\(error.localizedDescription)" } }
    @objc func modeChanged() { refresh() }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? { NSTextField(labelWithString:tableColumn?.identifier.rawValue == "heard" ? rows[row].heard : rows[row].term) }
    func tableViewSelectionDidChange(_ notification: Notification) { guard rows.indices.contains(table.selectedRow) else { return }; let row = rows[table.selectedRow]; heard.stringValue = row.heard; term.stringValue = row.term }
    @objc func accept() { do { let id = mode.selectedSegment == 0 && rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].id : nil; try store.accept(heard:heard.stringValue,term:term.stringValue,id:id); refresh(); info.stringValue = "已加入词库，下一次录音生效" } catch { info.stringValue = error.localizedDescription } }
    @objc func ignore() { guard rows.indices.contains(table.selectedRow) else { return }; do { if mode.selectedSegment == 0 { try store.dismiss(rows[table.selectedRow].id) } else { try store.removeAlias(rows[table.selectedRow].heard) }; refresh() } catch { info.stringValue = error.localizedDescription } }
}
