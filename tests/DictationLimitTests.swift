import Foundation

@main struct DictationLimitTests {
    static func main() {
        precondition(DictationLimit.effective(preference:nil,legacy:nil) == 180)
        precondition(DictationLimit.effective(preference:nil,legacy:90) == 90, "Keep existing users' 90-second setting")
        precondition(DictationLimit.effective(preference:240,legacy:90) == 240)
        for invalid: Any in [true, false, 0, -10, 29, 601, 90.5, Double.nan, Double.infinity, Double.greatestFiniteMagnitude, "90", NSNull()] {
            precondition(DictationLimit.validated(invalid) == nil)
            precondition(DictationLimit.effective(preference:invalid,legacy:90) == 90)
        }
        let suite = "freetalk-duration-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        defaults.set(137,forKey:DictationLimit.preferenceKey)
        let restored = UserDefaults(suiteName:suite)!.object(forKey:DictationLimit.preferenceKey)
        precondition(DictationLimit.effective(preference:restored,legacy:90) == 137)

        for limit in [30, 60, 90, 137, 180, 300, 600] {
            var clock = DictationClock(limit:Double(limit))
            precondition(clock.snapshot(at:10_000,audioSeconds:10).elapsed == 0, "Microphone preparation must not consume the budget")
            clock.start(at:1_000)
            precondition(clock.snapshot(at:1_000+Double(limit)-10.01).countdown == nil)
            precondition(clock.snapshot(at:1_000+Double(limit)-10).countdown == 10)
            var displayed = [Int]()
            for tenth in 0..<100 {
                let timing = clock.snapshot(at:1_000+Double(limit)-10+Double(tenth)/10)
                precondition(!timing.expired)
                if displayed.last != timing.countdown { displayed.append(timing.countdown!) }
            }
            precondition(displayed == Array((1...10).reversed()), "Every second must count down without showing zero early")
            let stopped = clock.snapshot(at:1_000+Double(limit))
            precondition(stopped.expired && stopped.countdown == 0)
            precondition(clock.snapshot(at:1_001+Double(limit)).remaining == 0)
            // A stopped audio callback must not leave the HUD counting forever.
            precondition(clock.snapshot(at:1_001+Double(limit),audioSeconds:3).expired)
            // An audio callback ahead of the wall clock also uses the same deadline.
            precondition(clock.snapshot(at:1_001,audioSeconds:Double(limit)).expired)
            precondition(clock.snapshot(at:999,audioSeconds:-1).elapsed == 0)
            precondition(clock.snapshot(at:1_002,audioSeconds:.nan).elapsed == 2)
            precondition(clock.snapshot(at:.nan,audioSeconds:2).elapsed == 2)
        }
        precondition(MeetingDuration.minutes(nil) == 240 && MeetingDuration.minutes(61) == 61)
        for invalid: Any in [true, 0, -1, 481, 0.5, "60"] { precondition(MeetingDuration.minutes(invalid) == 240) }
        var meeting = DictationClock(meetingMinutes: 240)
        precondition(meeting.snapshot(at: 50_000).elapsed == 0)
        meeting.start(at: 40)
        precondition(meeting.snapshot(at: 40 + 14100 - 0.01).countdown == nil)
        for n in 0...300 { precondition(meeting.snapshot(at: 40 + Double(14400-n)).countdown == n) }
        precondition(meeting.snapshot(at: 14440, audioSeconds: 20).expired)
        precondition(MeetingDuration.display(300) == "05:00" && MeetingDuration.display(14399) == "3:59:59")
        var short = DictationClock(meetingMinutes: 2); short.start(at: 0)
        precondition(short.snapshot(at: 0).countdown == 120)
        var original = DictationClock(limit:90); original.start(at:100)
        defaults.set(30,forKey:DictationLimit.preferenceKey)
        precondition(!original.snapshot(at:130).expired, "Changing preferences cannot shorten an active session")
        let next = DictationClock(limit:DictationLimit.effective(preference:defaults.object(forKey:DictationLimit.preferenceKey),legacy:90))
        precondition(next.limit == 30)
        print("Dictation duration passed: defaults, migration, persistence, validation, frozen session, all 10 countdown boundaries, stalled callbacks, monotonic stop")
    }
}
