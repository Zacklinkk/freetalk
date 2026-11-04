import Foundation
@main struct VocabularyTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("freetalk-vocabulary-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VocabularyStore(directory: directory)
        let empty = try store.load(); precondition(empty.isEmpty)
        let saved = try store.save("SFT\nsft\n\n 都都 \nDeepSeek")
        precondition(saved == ["SFT", "都都", "DeepSeek"])
        let reloaded = try VocabularyStore(directory: directory).load()
        precondition(reloaded == saved)
        let attrs = try FileManager.default.attributesOfItem(atPath: store.file.path)
        precondition((attrs[.posixPermissions] as! NSNumber).intValue == 0o600)
        do { _ = try store.save((0...200).map { "term\($0)" }.joined(separator: "\n")); fatalError("Must reject overflow") }
        catch is VocabularyError { }
        let after = try store.load(); precondition(after == saved)
        print("Vocabulary passed: normalization, reload, private permissions, rejected overflow preserves prior words")
    }
}
