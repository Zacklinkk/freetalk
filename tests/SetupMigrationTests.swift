import Foundation

@main struct SetupMigrationTests {
    static func main() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? manager.removeItem(at:root) }
        let old = root.appendingPathComponent("old"), new = root.appendingPathComponent("new")
        try manager.createDirectory(at:old,withIntermediateDirectories:true)
        try manager.createDirectory(at:new,withIntermediateDirectories:true)
        try Data("{\"asrModel\":\"/existing/model\"}".utf8).write(to:old.appendingPathComponent("config.json"))
        try Data("old history".utf8).write(to:old.appendingPathComponent("history.json"))
        try Data("new history".utf8).write(to:new.appendingPathComponent("history.json"))
        try Data("private".utf8).write(to:old.appendingPathComponent("unrelated.json"))
        try LegacyMigration.migrate(from:old,to:new)
        let newHistory = try String(contentsOf:new.appendingPathComponent("history.json"),encoding:.utf8)
        let oldHistory = try String(contentsOf:old.appendingPathComponent("history.json"),encoding:.utf8)
        assert(newHistory == "new history"); assert(oldHistory == "old history")
        assert(!manager.fileExists(atPath:new.appendingPathComponent("unrelated.json").path))
        let attributes = try manager.attributesOfItem(atPath:new.appendingPathComponent("config.json").path)
        assert(attributes[.posixPermissions] as? Int == 0o600)
        try LegacyMigration.migrate(from:old,to:new)
        assert(!ModelSetup.configured([:]))
        print("Migration: existing files preserved, scoped copy, private permissions, repeat safe")
    }
}
