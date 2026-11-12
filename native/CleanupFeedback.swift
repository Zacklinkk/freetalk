import Foundation

/// Cleanup cases: what the recognizer heard, what cleanup inserted and what the
/// user left after editing it.
struct CleanupFeedback: Codable, Equatable {
    var raw: String, inserted: String, final: String
    var createdAt: Date = Date()
}

final class CleanupFeedbackStore {
    static let limit = 60
    let file: URL
    init(directory: URL) { file = directory.appendingPathComponent("cleanup-feedback.json") }
    func load() -> [CleanupFeedback] {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: file)).flatMap { try? decoder.decode([CleanupFeedback].self, from: $0) } ?? []
    }
    /// Record a finished edit session. Returns false when it says nothing about cleanup.
    @discardableResult func record(raw: String, inserted: String, final: String) -> Bool {
        let plain = { (text: String) in InsertionCheck.normalize(text) }
        let raw = plain(raw), inserted = plain(inserted), final = plain(final)
        // Also keep cases where cleanup changed nothing: a missed filler or a bad
        // break is a cleanup problem too. The optimizer is told to ignore pure
        // recognition mistakes.
        guard final != inserted, !final.isEmpty, final.count <= 4000, inserted.count <= 4000 else { return false }
        // The user changed back toward the raw transcript, or changed text cleanup
        // touched; a pure addition at the end is new content, not a cleanup error.
        guard !final.hasPrefix(inserted) || final.count - inserted.count < 2 else { return false }
        var rows = load().filter { $0.raw != raw }
        rows.insert(CleanupFeedback(raw: raw, inserted: inserted, final: final), at: 0)
        save(Array(rows.prefix(Self.limit)))
        return true
    }
    func save(_ rows: [CleanupFeedback]) {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(rows) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    func clear() { try? FileManager.default.removeItem(at: file) }
}

/// The adopted cleanup preferences, read by the worker at startup.
enum CleanupPreferences {
    static func file(_ support: URL) -> URL { support.appendingPathComponent("cleanup-preferences.json") }
    static func load(_ support: URL) -> [String] {
        guard let data = try? Data(contentsOf: file(support)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return object["rules"] as? [String] ?? []
    }
    static func save(_ rules: [String], model: String, support: URL) throws {
        let object: [String: Any] = ["rules": rules, "model": model, "adoptedAt": ISO8601DateFormatter().string(from: Date())]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: file(support), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(support).path)
    }
}
