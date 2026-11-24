import Foundation
import CoreFoundation

enum DictationLimit {
    static let preferenceKey = "dictationLimitSeconds"
    static let defaultSeconds: TimeInterval = 180
    static let range = 30...600
    static let presets = [60, 90, 180, 300, 600]

    static func validated(_ value: Any?) -> TimeInterval? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let seconds = number.doubleValue
        guard seconds.isFinite, seconds.rounded() == seconds,
              seconds >= Double(range.lowerBound), seconds <= Double(range.upperBound) else { return nil }
        return seconds
    }

    static func effective(preference: Any?, legacy: Any?) -> TimeInterval {
        validated(preference) ?? validated(legacy) ?? defaultSeconds
    }

    static func title(_ seconds: TimeInterval) -> String {
        let value = Int(seconds)
        return value % 60 == 0 ? "\(value / 60) 分钟" : "\(value) 秒"
    }
}

struct DictationTiming {
    let limit: TimeInterval
    let elapsed: TimeInterval
    var remaining: TimeInterval { max(0, limit - elapsed) }
    var expired: Bool { elapsed >= limit }
    let warningSeconds: TimeInterval
    var countdown: Int? { remaining <= warningSeconds ? Int(ceil(remaining)) : nil }
}

/// The limit is frozen before microphone preparation. Preparation time does not
/// consume it. HUD and auto-stop share the same monotonic/audio clock, including
/// when callbacks pause or the system's calendar time changes.
struct DictationClock {
    let limit: TimeInterval
    private let warningSeconds: TimeInterval
    private(set) var startedAt: TimeInterval?

    init(limit: TimeInterval) {
        self.limit = DictationLimit.validated(limit) ?? DictationLimit.defaultSeconds
        warningSeconds = 10
    }

    init(meetingMinutes: Int) {
        limit = Double(MeetingDuration.minutes(meetingMinutes) * 60)
        warningSeconds = 300
    }

    mutating func start(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) { startedAt = uptime }

    func snapshot(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime, audioSeconds: TimeInterval = 0) -> DictationTiming {
        guard let start = startedAt else { return DictationTiming(limit: limit, elapsed: 0, warningSeconds: warningSeconds) }
        let wall = uptime.isFinite ? max(0, uptime - start) : 0
        let audio = audioSeconds.isFinite ? max(0, audioSeconds) : 0
        return DictationTiming(limit: limit, elapsed: max(wall, audio), warningSeconds: warningSeconds)
    }
}

enum MeetingDuration {
    static let range = 1...480
    static let defaultMinutes = 240
    static func minutes(_ value: Any?) -> Int {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == Double(number.intValue), range.contains(number.intValue)
        else { return defaultMinutes }
        return number.intValue
    }

    static func display(_ seconds: Int) -> String {
        seconds >= 3600 ? String(format:"%d:%02d:%02d",seconds/3600,seconds/60%60,seconds%60)
                        : String(format:"%02d:%02d",seconds/60,seconds%60)
    }
}
