import Foundation
import NaturalLanguage

/// What nightly maintenance learned from the dictation history: the domains
/// the user talks about and the terms those domains use. The terms are
/// low-priority hotwords for transcription; they never change text by
/// themselves. Lives in <support>/user-profile.json, readable only by the user.
struct UserProfile: Codable, Equatable {
    var createdAt: Date
    var model: String
    /// How many dictations the word counts came from.
    var dictations: Int
    var domains: [String]
    var terms: [String]

    /// Fewer dictations than this say too little about the user.
    static let minimumDictations = 20
    /// A profile is rebuilt once this many dictations were added since it was made.
    static let refreshAfter = 10

    static func file(_ support: URL) -> URL { support.appendingPathComponent("user-profile.json") }
    static func load(_ support: URL) -> UserProfile? {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: file(support))).flatMap { try? decoder.decode(UserProfile.self, from: $0) }
    }
    func save(_ support: URL) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = Self.file(support)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try encoder.encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func clear(_ support: URL) { try? FileManager.default.removeItem(at: file(support)) }

    /// Whether the history grew enough since `profile` was made to build it again.
    static func due(_ profile: UserProfile?, history: [Date]) -> Bool {
        guard history.count >= minimumDictations else { return false }
        guard let profile = profile else { return true }
        return history.filter { $0 > profile.createdAt }.count >= refreshAfter
    }

    /// Words said in at least `minimum` dictations, the most widespread first.
    /// Only words and counts leave here, never sentences: English tokens as
    /// written, Chinese words from the system's word segmentation. Everyday
    /// words say nothing about a domain and are left out.
    static func statistics(_ texts: [String], minimum: Int = 3, limit: Int = 150) -> [(term: String, count: Int)] {
        var dictations: [String: Int] = [:], spellings: [String: [String: Int]] = [:]
        let latin = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9_])[A-Za-z][A-Za-z0-9_+.#-]{1,39}")
        let tokenizer = NLTokenizer(unit: .word); tokenizer.setLanguage(.simplifiedChinese)
        for text in texts {
            var seen = Set<String>()
            func add(_ word: String) {
                let key = word.lowercased()
                spellings[key, default: [:]][word, default: 0] += 1
                if seen.insert(key).inserted { dictations[key, default: 0] += 1 }
            }
            let ns = text as NSString
            for match in latin.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let word = ns.substring(with: match.range).trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
                if word.count >= 2, !commonEnglish.contains(word.lowercased()) { add(word) }
            }
            tokenizer.string = text
            tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
                let word = String(text[range])
                if (2...8).contains(word.count), word.unicodeScalars.allSatisfy({ (0x4E00...0x9FFF).contains($0.value) }), !commonChinese.contains(word) { add(word) }
                return true
            }
        }
        let rows = dictations.filter { $0.value >= minimum }.map { key, count in
            // The spelling the user wrote most often: SFT, not sft.
            (term: spellings[key]!.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }!.key, count: count)
        }
        return Array(rows.sorted { $0.count != $1.count ? $0.count > $1.count : $0.term < $1.term }.prefix(limit))
    }

    static let commonEnglish: Set<String> = ["the", "and", "or", "of", "to", "in", "on", "at", "for", "with", "from", "by", "as", "is", "are", "was",
        "were", "be", "been", "it", "its", "this", "that", "these", "those", "we", "you", "he", "she", "they", "me", "my", "our", "your", "us",
        "an", "if", "so", "no", "not", "yes", "ok", "okay", "do", "does", "did", "can", "will", "just", "but", "all", "any", "some", "have", "has",
        "what", "how", "why", "when", "then", "there", "here", "about", "into", "out", "up", "also", "very", "more", "one", "two", "hi", "hello"]
    static let commonChinese: Set<String> = ["我们", "你们", "他们", "她们", "咱们", "大家", "自己", "这个", "那个", "这些", "那些", "这种", "那种", "这样",
        "那样", "这里", "那里", "这边", "那边", "一个", "一下", "一些", "一点", "一起", "一直", "一样", "一定", "可以", "可能", "应该", "需要", "就是",
        "然后", "现在", "已经", "还是", "还有", "或者", "而且", "但是", "因为", "所以", "如果", "虽然", "不过", "其实", "比如", "例如", "包括", "以及",
        "没有", "不是", "不要", "不能", "不会", "不用", "什么", "怎么", "为什么", "怎么样", "哪些", "哪里", "多少", "时候", "之后", "之前", "以后",
        "以前", "刚才", "今天", "明天", "昨天", "东西", "事情", "问题", "地方", "方面", "情况", "部分", "时间", "觉得", "知道", "看看", "看到", "看一下",
        "帮我", "帮忙", "告诉", "说明", "直接", "继续", "开始", "结束", "完成", "进行", "使用", "出来", "起来", "下来", "上面", "下面", "里面", "后面",
        "前面", "中间", "另外", "同时", "每个", "所有", "其他", "其它", "只是", "只要", "只有", "能够", "是否", "的话", "好的", "对的", "是的", "谢谢",
        "非常", "比较", "特别", "真的", "确实", "感觉", "发现", "希望", "意思", "一般", "当前", "目前", "之类", "然后呢", "那么", "这么", "怎样"]
}

/// Which nightly steps run. Both use the strong cloud model.
struct NightlySettings: Equatable {
    var enabled = false, profile = false, tuning = false
    static func load(_ d: UserDefaults = .standard) -> Self {
        var s = Self()
        // Before 0.8 rule tuning was the only nightly step, switched on in the cloud card.
        s.tuning = d.bool(forKey: "cloudNightlyTuning")
        s.enabled = d.object(forKey: "nightlyMaintenance") as? Bool ?? s.tuning
        s.profile = d.bool(forKey: "nightlyProfile")
        return s
    }
    func save(_ d: UserDefaults = .standard) {
        d.set(enabled, forKey: "nightlyMaintenance"); d.set(profile, forKey: "nightlyProfile"); d.set(tuning, forKey: "cloudNightlyTuning")
    }
    /// A step will run tonight.
    var active: Bool { enabled && (profile || tuning) }
    /// The profile's terms help transcription while its step is on.
    var usesProfile: Bool { enabled && profile }

    /// Once a night between 00:30 and 06:00, 15 minutes after the last dictation.
    static func due(now: Date, lastRun: Date?, lastDictation: Date?, calendar: Calendar = .current) -> Bool {
        let minutes = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        guard (30..<360).contains(minutes) else { return false }
        if let last = lastRun, calendar.isDate(last, inSameDayAs: now) { return false }
        if let recent = lastDictation, now.timeIntervalSince(recent) < 15 * 60 { return false }
        return true
    }
}
