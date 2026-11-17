import Foundation
@main struct UserProfileTests {
    static func main() throws {
        // Only words said in three dictations or more, in the user's spelling, everyday words left out.
        let texts = ["我们用 SFT 跑一下这个模型的评测。", "SFT 之后看 benchmark 分数。", "sft 数据还没准备好，模型先等等。",
                     "明天把 benchmark 结果发我，模型那边也看一下。", "Benchmark 和 SFT 都要再跑。", "今天天气不错，我们出去走走吧。"]
        let stats = UserProfile.statistics(texts)
        let found = Dictionary(uniqueKeysWithValues: stats.map { ($0.term, $0.count) })
        precondition(found["SFT"] == 4 && found["benchmark"] == 3 && found["模型"] == 3, "\(stats)")
        precondition(found["我们"] == nil && found["一下"] == nil && found["天气"] == nil, "\(stats)")
        precondition(stats.first?.term == "SFT")
        precondition(UserProfile.statistics(texts, limit: 1).count == 1)

        // A profile is built at 20 dictations and rebuilt after 10 more.
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let dates = (0..<25).map { start.addingTimeInterval(Double($0) * 60) }
        precondition(!UserProfile.due(nil, history: Array(dates.prefix(19))) && UserProfile.due(nil, history: dates))
        let profile = UserProfile(createdAt: dates[19], model: "strong", dictations: 20, domains: ["大模型评测"], terms: ["SFT", "benchmark"])
        precondition(!UserProfile.due(profile, history: dates))
        precondition(UserProfile.due(profile, history: dates + (25..<30).map { start.addingTimeInterval(Double($0) * 60) }))

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("freetalk-profile-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        precondition(UserProfile.load(dir) == nil)
        try profile.save(dir)
        precondition(UserProfile.load(dir) == profile)
        let attributes = try FileManager.default.attributesOfItem(atPath: UserProfile.file(dir).path)
        precondition((attributes[.posixPermissions] as! NSNumber).intValue == 0o600)
        UserProfile.clear(dir); precondition(UserProfile.load(dir) == nil)

        // Nightly settings: rule tuning switched on before 0.8 turns maintenance on; the profile step needs opting in.
        let suite = "freetalk-nightly-tests-\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        precondition(NightlySettings.load(defaults) == NightlySettings())
        defaults.set(true, forKey: "cloudNightlyTuning")
        let upgraded = NightlySettings.load(defaults)
        precondition(upgraded.enabled && upgraded.tuning && !upgraded.profile && upgraded.active && !upgraded.usesProfile)
        NightlySettings(enabled: false, profile: true, tuning: true).save(defaults)
        precondition(!NightlySettings.load(defaults).active && !NightlySettings.load(defaults).usesProfile)

        // The window: 00:30–06:00, once a night, 15 minutes after the last dictation.
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        func at(_ hour: Int, _ minute: Int, day: Int = 18) -> Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))! }
        precondition(!NightlySettings.due(now: at(0, 29), lastRun: nil, lastDictation: nil, calendar: calendar))
        precondition(NightlySettings.due(now: at(0, 30), lastRun: nil, lastDictation: nil, calendar: calendar))
        precondition(!NightlySettings.due(now: at(6, 0), lastRun: nil, lastDictation: nil, calendar: calendar))
        precondition(!NightlySettings.due(now: at(1, 0), lastRun: at(0, 40), lastDictation: nil, calendar: calendar))
        precondition(NightlySettings.due(now: at(1, 0), lastRun: at(0, 40, day: 17), lastDictation: nil, calendar: calendar))
        precondition(!NightlySettings.due(now: at(1, 0), lastRun: nil, lastDictation: at(0, 50), calendar: calendar))
        precondition(NightlySettings.due(now: at(1, 0), lastRun: nil, lastDictation: at(0, 44), calendar: calendar))
        print("User profile passed: word statistics, everyday words dropped, rebuild threshold, 0600, nightly settings migration, nightly window")
    }
}
